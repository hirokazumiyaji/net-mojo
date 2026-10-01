#!/usr/bin/env bash
# HTTPS + HTTP/2 load harness for Issue #42 PR 9.
#
# Load tool: h2load (Homebrew nghttp2). ALPN forced to h2.
# Samples server CPU / RSS / fd while h2load runs; parses --log-file for
# p50/p95/p99 latency.
#
# Usage (from repository root, after tls-build + hpack-test):
#   bash benchmarks/http/run_http2_bench.sh
#
# Environment overrides:
#   WARMUP_S   warmup seconds (default 5)
#   MEASURE_S  measure seconds (default 10)
#   RUNS       repetitions (default 3)
#   CLIENTS    h2load -c connections (default 64)
#   STREAMS    space-separated max concurrent streams (default "1 10")
#   SKIP_GO=1 / SKIP_MOJO=1 to skip one side
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WARMUP_S="${WARMUP_S:-5}"
MEASURE_S="${MEASURE_S:-10}"
RUNS="${RUNS:-3}"
CLIENTS="${CLIENTS:-64}"
STREAMS="${STREAMS:-1 10}"
GO_ADDR="127.0.0.1:18442"
MOJO_ADDR="127.0.0.1:18443"
OUT_DIR="${OUT_DIR:-build/bench/http2}"
GO_BIN="${GO_BIN:-$OUT_DIR/http_go_h2}"
MOJO_BIN="${MOJO_BIN:-$OUT_DIR/http2_tls_server}"
BENCH_FAILURES=0

if ! command -v h2load >/dev/null; then
    echo "h2load not found; install with: brew install nghttp2" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

for artifact in build/tls/libnet_tls build/tls/test-cert.pem build/tls/test-key.pem; do
    [ -f "$artifact" ] || {
        echo "missing $artifact; run: pixi run -e tls-http2 tls-build" >&2
        exit 1
    }
done
[ -f build/http2/libnet_hpack ] || {
    echo "missing build/http2/libnet_hpack; run: pixi run -e tls-http2 hpack-test" >&2
    exit 1
}

echo "== host =="
uname -a
sw_vers 2>/dev/null || true
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
echo "go: $(go version)"
echo "mojo: $(mojo --version 2>/dev/null || echo unknown)"
echo "h2load: $(h2load --version 2>&1 | head -1)"
echo "openssl (system): $(openssl version 2>/dev/null || true)"
if [ -x /opt/homebrew/opt/openssl@3/bin/openssl ]; then
    echo "openssl@3: $(/opt/homebrew/opt/openssl@3/bin/openssl version)"
fi
if command -v pkg-config >/dev/null && pkg-config --exists openssl 2>/dev/null; then
    echo "pkg-config openssl: $(pkg-config --modversion openssl) ($(pkg-config --variable=prefix openssl))"
fi
echo "procedure: warmup=${WARMUP_S}s measure=${MEASURE_S}s runs=${RUNS} clients=${CLIENTS} streams=[${STREAMS}]"
echo

build_go() {
    go -C benchmarks/http_go build -o "$ROOT/$GO_BIN" .
}

build_mojo() {
    pixi run -e tls-http2 mojo build --Werror -I . \
        benchmarks/http2_tls_server.mojo -o "$MOJO_BIN"
}

sample_server() {
    # Args: pid outfile
    local pid="$1"
    local file="$2"
    local cpu rss fds
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")"
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")"
    if command -v lsof >/dev/null; then
        # Count only numeric file descriptors; lsof output includes a
        # header plus cwd/txt entries that inflate `wc -l`.
        fds="$(lsof -nP -p "$pid" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+[rwu-]*$/ {n++} END{print n+0}')"
        [ -n "$fds" ] || fds="?"
    else
        fds="?"
    fi
    printf 'cpu_pct=%s rss_kb=%s fd_count=%s\n' "$cpu" "$rss" "$fds" >"$file"
}

percentile() {
    # unused placeholder kept for optional lat-file fallback
    local p="$1"
    python3 - "$p" <<'PY'
import sys
p = float(sys.argv[1])
vals = sorted(int(x) for x in sys.stdin if x.strip())
if not vals:
    print("nan")
    raise SystemExit(0)
k = max(1, int(round(p / 100.0 * len(vals))))
print(vals[min(k, len(vals)) - 1])
PY
}

# Convert h2load duration token (e.g. 114us, 1.25ms, 2.00s) to microseconds.
to_us() {
    python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
if s in ("", "N/A", "nan"):
    print("nan")
    raise SystemExit(0)
num = float(''.join(c for c in s if c.isdigit() or c == '.' or c == '-'))
if s.endswith("us"):
    print(int(round(num)))
elif s.endswith("ms"):
    print(int(round(num * 1000)))
elif s.endswith("s"):
    print(int(round(num * 1_000_000)))
else:
    print(int(round(num)))
PY
}

run_h2load() {
    # Args: label url clients streams run_idx server_pid
    local label="$1"
    local url="$2"
    local clients="$3"
    local streams="$4"
    local run_idx="$5"
    local server_pid="$6"
    local log="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.log"
    local lat="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.lat"
    local sample="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.sample"
    local out="$OUT_DIR/${label}_c${clients}_m${streams}_r${run_idx}.out"

    (
        sleep $((WARMUP_S + MEASURE_S / 2))
        sample_server "$server_pid" "$sample"
    ) &
    local sampler_pid=$!

    set +e
    h2load \
        --alpn-list=h2 \
        -c "$clients" \
        -m "$streams" \
        -t 1 \
        --warm-up-time="${WARMUP_S}s" \
        -D "${MEASURE_S}s" \
        --log-file="$lat" \
        "$url" >"$out" 2>&1
    local rc=$?
    set -e
    wait "$sampler_pid" 2>/dev/null || true
    if [ ! -f "$sample" ]; then
        sample_server "$server_pid" "$sample"
    fi

    local req_s success failed
    req_s="$(rg -o 'finished in [^,]+, ([0-9.]+) req/s' -r '$1' "$out" | head -1 || true)"
    success="$(rg -o 'requests: .* ([0-9]+) succeeded' -r '$1' "$out" | head -1 || true)"
    failed="$(rg -o 'requests: .* ([0-9]+) failed' -r '$1' "$out" | head -1 || true)"

    # h2load request row: min max median p95 p99 mean sd +/-sd
    # Fields after splitting on whitespace: $1=request $2=: $3=min $4=max
    # $5=median $6=p95 $7=p99 ...
    local med_tok p95_tok p99_tok
    med_tok="$(rg '^\s*request\s*:' "$out" | awk '{print $5}' | head -1 || true)"
    p95_tok="$(rg '^\s*request\s*:' "$out" | awk '{print $6}' | head -1 || true)"
    p99_tok="$(rg '^\s*request\s*:' "$out" | awk '{print $7}' | head -1 || true)"
    local p50 p95 p99
    p50="$(to_us "${med_tok:-}")"
    p95="$(to_us "${p95_tok:-}")"
    p99="$(to_us "${p99_tok:-}")"

    local sample_line
    sample_line="$(tr '\n' ' ' <"$sample" | sed 's/ *$//')"

    printf '%s\tc=%s\tm=%s\trun=%s\treq_s=%s\tp50_us=%s\tp95_us=%s\tp99_us=%s\tsucceeded=%s\tfailed=%s\trc=%s\t%s\n' \
        "$label" "$clients" "$streams" "$run_idx" \
        "${req_s:-?}" "$p50" "$p95" "$p99" \
        "${success:-?}" "${failed:-?}" "$rc" "$sample_line" \
        | tee -a "$OUT_DIR/summary.tsv"

    cp "$out" "$log"
    if [ "$rc" -ne 0 ]; then
        BENCH_FAILURES=$((BENCH_FAILURES + 1))
        echo "benchmark failed: $label c=$clients m=$streams run=$run_idx rc=$rc (see $out)" >&2
    fi
    return 0
}

wait_listen() {
    local hostport="$1"
    local pid="$2"
    local i
    for i in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "server $pid exited before listen on $hostport" >&2
            return 1
        fi
        if python3 - "$hostport" <<'PY'
import socket, sys
host, port = sys.argv[1].rsplit(":", 1)
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect((host, int(port)))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
        then
            return 0
        fi
        sleep 0.1
    done
    echo "timeout waiting for $hostport" >&2
    return 1
}

kill_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

: >"$OUT_DIR/summary.tsv"
echo -e "label\tc\tm\trun\treq_s\tp50_us\tp95_us\tp99_us\tsucceeded\tfailed\trc\tsamples" >>"$OUT_DIR/summary.tsv"

if [ "${SKIP_GO:-0}" != "1" ]; then
    echo "== build Go HTTPS+H2 baseline =="
    build_go
    echo "== verify Go /fixed =="
    GOMAXPROCS=1 "$GO_BIN" -tls -addr "$GO_ADDR" \
        -cert build/tls/test-cert.pem -key build/tls/test-key.pem \
        >"$OUT_DIR/go_server.log" 2>&1 &
    GO_PID=$!
    trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_PID:-}"' EXIT
    wait_listen "$GO_ADDR" "$GO_PID"
    # Quick ALPN smoke with openssl s_client if available.
    python3 - "$GO_ADDR" <<'PY'
import socket, ssl, sys
host, port = sys.argv[1].rsplit(":", 1)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.set_alpn_protocols(["h2"])
with socket.create_connection((host, int(port)), timeout=3) as raw:
    with ctx.wrap_socket(raw, server_hostname="localhost") as s:
        assert s.selected_alpn_protocol() == "h2", s.selected_alpn_protocol()
print("go alpn=h2 ok")
PY
    for streams in $STREAMS; do
        for run in $(seq 1 "$RUNS"); do
            echo "== Go GET /fixed c=${CLIENTS} m=${streams} run=${run} =="
            run_h2load "go" "https://${GO_ADDR}/fixed" "$CLIENTS" "$streams" "$run" "$GO_PID"
        done
    done
    kill_pid "$GO_PID"
    GO_PID=
fi

if [ "${SKIP_MOJO:-0}" != "1" ]; then
    echo "== build Mojo HTTPS+H2 bench server =="
    build_mojo
    echo "== verify Mojo /fixed =="
    "$MOJO_BIN" >"$OUT_DIR/mojo_server.log" 2>&1 &
    MOJO_PID=$!
    trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_PID:-}"' EXIT
    wait_listen "$MOJO_ADDR" "$MOJO_PID"
    python3 - "$MOJO_ADDR" <<'PY'
import socket, ssl, sys
host, port = sys.argv[1].rsplit(":", 1)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.set_alpn_protocols(["h2"])
with socket.create_connection((host, int(port)), timeout=3) as raw:
    with ctx.wrap_socket(raw, server_hostname="localhost") as s:
        assert s.selected_alpn_protocol() == "h2", s.selected_alpn_protocol()
print("mojo alpn=h2 ok")
PY
    for streams in $STREAMS; do
        for run in $(seq 1 "$RUNS"); do
            echo "== Mojo GET /fixed c=${CLIENTS} m=${streams} run=${run} =="
            run_h2load "mojo" "https://${MOJO_ADDR}/fixed" "$CLIENTS" "$streams" "$run" "$MOJO_PID"
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
