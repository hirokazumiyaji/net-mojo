#!/usr/bin/env bash
# HTTP/3 (QUIC ALPN h3) load harness for Issue #42 PR 10.
#
# Baseline: pinned aioquic==1.3.0 server (pixi feature.http3).
# Mojo: optimized build of benchmarks/http3_server.mojo (quiche provider).
# Load tool: benchmarks/http3_load.py (aioquic client). Homebrew h2load
# bottles typically ship without ngtcp2/nghttp3, so --h3 is not usable here.
#
# Samples server CPU / RSS / fd mid-measure; reports req/s and p50/p95/p99.
#
# Usage (from repository root, after tls-build + quic-build):
#   bash benchmarks/http/run_http3_bench.sh
#
# Environment overrides:
#   WARMUP_S   warmup seconds (default 5)
#   MEASURE_S  measure seconds (default 10)
#   RUNS       repetitions (default 3)
#   CLIENTS    QUIC connections (default 64)
#   STREAMS    space-separated max concurrent streams per conn (default "1 10")
#   LOSS_PCT   optional induced loss label only (default 0); harness does not
#              configure a netem/pf path — record LOSS_PCT in the summary when
#              the operator applies loss out-of-band.
#   SKIP_BASELINE=1 / SKIP_MOJO=1 to skip one side
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WARMUP_S="${WARMUP_S:-5}"
MEASURE_S="${MEASURE_S:-10}"
RUNS="${RUNS:-3}"
CLIENTS="${CLIENTS:-64}"
STREAMS="${STREAMS:-1 10}"
LOSS_PCT="${LOSS_PCT:-0}"
BASELINE_ADDR="127.0.0.1:18452"
MOJO_ADDR="127.0.0.1:18453"
OUT_DIR="${OUT_DIR:-build/bench/http3}"
MOJO_BIN="${MOJO_BIN:-$OUT_DIR/http3_server}"
BENCH_FAILURES=0
PIXI_ENV="${PIXI_ENV:-tls-http3}"
# Resolve the env interpreter once so backgrounded servers are the real
# Python process (not a pixi wrapper), which matters for CPU/RSS sampling.
PIXI_PYTHON="${PIXI_PYTHON:-$(cd "$ROOT" && pixi run -e "$PIXI_ENV" python -c 'import sys; print(sys.executable)')}"

mkdir -p "$OUT_DIR"

for artifact in build/tls/test-cert.pem build/tls/test-key.pem; do
    [ -f "$artifact" ] || {
        echo "missing $artifact; run: pixi run -e $PIXI_ENV tls-build && pixi run -e $PIXI_ENV quic-build" >&2
        exit 1
    }
done
if [ "${SKIP_MOJO:-0}" != "1" ] && [ ! -f build/quic/libnet_quic_provider ]; then
    echo "missing build/quic/libnet_quic_provider; run: pixi run -e $PIXI_ENV quic-build (or SKIP_MOJO=1 for baseline-only)" >&2
    exit 1
fi

echo "== host =="
uname -a
sw_vers 2>/dev/null || true
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
echo "mojo: $(pixi run -e "$PIXI_ENV" mojo --version 2>/dev/null || echo unknown)"
echo "aioquic: $("$PIXI_PYTHON" -c 'import aioquic; print(aioquic.__version__)')"
echo "python: $PIXI_PYTHON"
echo "quiche (provider Cargo.lock): $(rg -N '^name = \"quiche\"' -A1 net/quic/provider/Cargo.lock | rg -N 'version' | head -1 || echo pinned in Cargo.toml =0.29.3)"
echo "procedure: warmup=${WARMUP_S}s measure=${MEASURE_S}s runs=${RUNS} clients=${CLIENTS} streams=[${STREAMS}] loss_pct=${LOSS_PCT} (label; not injected by harness)"
echo

sample_server() {
    local pid="$1"
    local file="$2"
    local cpu rss fds
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")"
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")"
    if command -v lsof >/dev/null; then
        fds="$(lsof -nP -p "$pid" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+[rwu-]*$/ {n++} END{print n+0}')"
        [ -n "$fds" ] || fds="?"
    else
        fds="?"
    fi
    printf 'cpu_pct=%s rss_kb=%s fd_count=%s\n' "$cpu" "$rss" "$fds" >"$file"
}

wait_udp() {
    # Best-effort: wait until the server process is alive; UDP listen has no
    # TCP connect probe. Optional smoke via a short aioquic GET.
    local hostport="$1"
    local pid="$2"
    local i
    for i in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "server $pid exited before ready on $hostport" >&2
            return 1
        fi
        sleep 0.1
    done
    return 0
}

smoke_get() {
    local url="$1"
    "$PIXI_PYTHON" benchmarks/http3_load.py \
        --url "$url" --clients 1 --streams 1 --warmup 0 --duration 1 \
        >"$OUT_DIR/smoke.out" 2>"$OUT_DIR/smoke.err" || {
        echo "smoke GET failed for $url" >&2
        cat "$OUT_DIR/smoke.err" >&2 || true
        return 1
    }
    if ! rg -q 'ok=[1-9]' "$OUT_DIR/smoke.out"; then
        echo "smoke GET produced no successes: $(cat "$OUT_DIR/smoke.out")" >&2
        cat "$OUT_DIR/smoke.err" >&2 || true
        return 1
    fi
    echo "smoke ok: $(cat "$OUT_DIR/smoke.out")"
}

run_load() {
    local label="$1"
    local url="$2"
    local clients="$3"
    local streams="$4"
    local run_idx="$5"
    local server_pid="$6"
    local out="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.out"
    local sample="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.sample"
    local log="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.log"

    (
        sleep $((WARMUP_S + MEASURE_S / 2))
        sample_server "$server_pid" "$sample"
    ) &
    local sampler_pid=$!

    set +e
    "$PIXI_PYTHON" benchmarks/http3_load.py \
        --url "$url" \
        --clients "$clients" \
        --streams "$streams" \
        --warmup "$WARMUP_S" \
        --duration "$MEASURE_S" \
        >"$out" 2>"$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.err"
    local rc=$?
    set -e
    wait "$sampler_pid" 2>/dev/null || true
    if [ ! -f "$sample" ]; then
        sample_server "$server_pid" "$sample"
    fi

    local line req_s p50 p95 p99 ok failed
    line="$(rg -N '^req_s=' "$out" | tail -1 || true)"
    req_s="$(printf '%s' "$line" | rg -o 'req_s=([0-9.]+)' -r '$1' || true)"
    p50="$(printf '%s' "$line" | rg -o 'p50_us=([0-9.]+)' -r '$1' || true)"
    p95="$(printf '%s' "$line" | rg -o 'p95_us=([0-9.]+)' -r '$1' || true)"
    p99="$(printf '%s' "$line" | rg -o 'p99_us=([0-9.]+)' -r '$1' || true)"
    ok="$(printf '%s' "$line" | rg -o 'ok=([0-9]+)' -r '$1' || true)"
    failed="$(printf '%s' "$line" | rg -o 'failed=([0-9]+)' -r '$1' || true)"

    local sample_line
    sample_line="$(tr '\n' ' ' <"$sample" | sed 's/ *$//')"

    printf '%s\tc=%s\tm=%s\trun=%s\tloss_pct=%s\treq_s=%s\tp50_us=%s\tp95_us=%s\tp99_us=%s\tok=%s\tfailed=%s\trc=%s\t%s\n' \
        "$label" "$clients" "$streams" "$run_idx" "$LOSS_PCT" \
        "${req_s:-?}" "${p50:-?}" "${p95:-?}" "${p99:-?}" \
        "${ok:-?}" "${failed:-?}" "$rc" "$sample_line" \
        | tee -a "$OUT_DIR/summary.tsv"

    cp "$out" "$log"
    if [ "$rc" -ne 0 ]; then
        BENCH_FAILURES=$((BENCH_FAILURES + 1))
        echo "benchmark failed: $label c=$clients m=$streams run=$run_idx rc=$rc (see $out)" >&2
    fi
    return 0
}

kill_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

build_mojo() {
    pixi run -e "$PIXI_ENV" mojo build --Werror -I . \
        benchmarks/http3_server.mojo -o "$MOJO_BIN"
}

: >"$OUT_DIR/summary.tsv"
echo -e "label\tc\tm\trun\tloss_pct\treq_s\tp50_us\tp95_us\tp99_us\tok\tfailed\trc\tsamples" >>"$OUT_DIR/summary.tsv"

if [ "${SKIP_BASELINE:-0}" != "1" ]; then
    echo "== start aioquic HTTP/3 baseline =="
    "$PIXI_PYTHON" benchmarks/http3_aioquic_baseline.py \
        --host 127.0.0.1 --port 18452 \
        --certificate build/tls/test-cert.pem \
        --private-key build/tls/test-key.pem \
        >"$OUT_DIR/baseline_server.log" 2>&1 &
    BASE_PID=$!
    trap 'kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_PID:-}"' EXIT
    wait_udp "$BASELINE_ADDR" "$BASE_PID"
    smoke_get "https://${BASELINE_ADDR}/fixed"
    for streams in $STREAMS; do
        for run in $(seq 1 "$RUNS"); do
            echo "== baseline GET /fixed c=${CLIENTS} m=${streams} run=${run} =="
            run_load "aioquic" "https://${BASELINE_ADDR}/fixed" "$CLIENTS" "$streams" "$run" "$BASE_PID"
        done
    done
    kill_pid "$BASE_PID"
    BASE_PID=
fi

if [ "${SKIP_MOJO:-0}" != "1" ]; then
    echo "== build Mojo HTTP/3 bench server =="
    build_mojo
    echo "== start Mojo HTTP/3 =="
    "$MOJO_BIN" >"$OUT_DIR/mojo_server.log" 2>&1 &
    MOJO_PID=$!
    trap 'kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_PID:-}"' EXIT
    wait_udp "$MOJO_ADDR" "$MOJO_PID"
    smoke_get "https://${MOJO_ADDR}/fixed"
    for streams in $STREAMS; do
        for run in $(seq 1 "$RUNS"); do
            echo "== Mojo GET /fixed c=${CLIENTS} m=${streams} run=${run} =="
            run_load "mojo" "https://${MOJO_ADDR}/fixed" "$CLIENTS" "$streams" "$run" "$MOJO_PID"
        done
    done
    kill_pid "$MOJO_PID"
    MOJO_PID=
fi

echo
echo "== summary ($OUT_DIR/summary.tsv) =="
column -t -s $'\t' "$OUT_DIR/summary.tsv" 2>/dev/null || cat "$OUT_DIR/summary.tsv"
if [ "$BENCH_FAILURES" -gt 0 ]; then
    echo "$BENCH_FAILURES benchmark run(s) failed" >&2
    exit 1
fi
