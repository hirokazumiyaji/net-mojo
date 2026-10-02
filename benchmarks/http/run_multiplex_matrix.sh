#!/usr/bin/env bash
# Multiplex matrix + special scenarios for Issue #42 PR 11.
#
# Varies connections × streams independently for GET /fixed on HTTPS+H2 and
# QUIC H3. Also runs slow-stream, cancel, and one loss scenario per protocol.
#
# Procedure is intentionally shortened vs full Phase 0 and labeled as such
# (defaults: warmup 3 s, measure 8 s, 3 runs). Never invent numbers — only
# record what this harness prints.
#
# Usage (from repository root, after tls/hpack/quic builds):
#   bash benchmarks/http/run_multiplex_matrix.sh
#
# Environment overrides:
#   WARMUP_S MEASURE_S RUNS CONNS STREAMS
#   SKIP_H2=1 SKIP_H3=1 SKIP_SPECIAL=1
#   SKIP_GO=1 SKIP_MOJO=1 SKIP_BASELINE=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WARMUP_S="${WARMUP_S:-3}"
MEASURE_S="${MEASURE_S:-8}"
RUNS="${RUNS:-3}"
CONNS="${CONNS:-1 16 64}"
STREAMS="${STREAMS:-1 10}"
OUT_DIR="${OUT_DIR:-build/bench/matrix}"
GO_ADDR="127.0.0.1:18442"
MOJO_H2_ADDR="127.0.0.1:18443"
BASELINE_H3_ADDR="127.0.0.1:18452"
MOJO_H3_ADDR="127.0.0.1:18453"
GO_BIN="${GO_BIN:-$OUT_DIR/http_go_h2}"
MOJO_H2_BIN="${MOJO_H2_BIN:-$OUT_DIR/http2_tls_server}"
MOJO_H3_BIN="${MOJO_H3_BIN:-$OUT_DIR/http3_server}"
PIXI_ENV_H2="${PIXI_ENV_H2:-tls-http2}"
PIXI_ENV_H3="${PIXI_ENV_H3:-tls-http3}"
# Resolved lazily inside each protocol branch so an H2-only or H3-only run
# (SKIP_H2=1 / SKIP_H3=1) never requires the other pixi env at startup.
PIXI_PYTHON_H2="${PIXI_PYTHON_H2:-}"
PIXI_PYTHON_H3="${PIXI_PYTHON_H3:-}"
MATRIX_FAILURES=0

h3_python() {
    if [ -n "${PIXI_PYTHON_H3:-}" ]; then
        printf '%s' "$PIXI_PYTHON_H3"
        return 0
    fi
    PIXI_PYTHON_H3="$(cd "$ROOT" && pixi run -e "$PIXI_ENV_H3" python -c 'import sys; print(sys.executable)')"
    printf '%s' "$PIXI_PYTHON_H3"
}

# Same lazy resolution for the H2 side: the H3-only path (SKIP_H2=1) must
# never need the tls-http2 environment at startup.
h2_python() {
    if [ -n "${PIXI_PYTHON_H2:-}" ]; then
        printf '%s' "$PIXI_PYTHON_H2"
        return 0
    fi
    PIXI_PYTHON_H2="$(cd "$ROOT" && pixi run -e "$PIXI_ENV_H2" python -c 'import sys; print(sys.executable)')"
    printf '%s' "$PIXI_PYTHON_H2"
}

mkdir -p "$OUT_DIR" "$OUT_DIR/h2" "$OUT_DIR/h3" "$OUT_DIR/special"

echo "== multiplex matrix host =="
uname -a
sw_vers 2>/dev/null || true
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
echo "procedure: SHORTENED warmup=${WARMUP_S}s measure=${MEASURE_S}s runs=${RUNS}"
echo "matrix: conns=[${CONNS}] streams=[${STREAMS}] GET /fixed"
echo

kill_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

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

# Mid-run sample point: warmup plus half the measure window. WARMUP_S and
# MEASURE_S are durations that both clients accept as fractions, and Bash
# arithmetic expansion is integer-only, so `$((...))` would abort this
# subshell (leaving a stale .sample file or a post-load fallback sample)
# for a value like MEASURE_S=0.5. Compute the delay with float arithmetic,
# as run_http2_bench.sh and run_http3_bench.sh do.
sampler_delay() {
    python3 -c 'import sys; print(float(sys.argv[1]) + float(sys.argv[2]) / 2)' \
        "$WARMUP_S" "$MEASURE_S"
}

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

verify_fixed_h2() {
    # Preflight: GET /fixed over HTTP/2 must return 200 with exactly the
    # 64-byte payload both servers serve. Measuring a non-equivalent
    # handler would make the Go/Mojo comparison meaningless.
    local label="$1"
    local addr="$2"
    local body="$OUT_DIR/special/${label}_verify_body.bin"
    local result code ver
    result="$(curl -k --http2 -sS --max-time 10 -o "$body" \
        -w '%{http_code} %{http_version}' "https://${addr}/fixed")"
    code="${result% *}"
    ver="${result#* }"
    if [ "$code" != "200" ] || [ "$ver" != "2" ] \
        || [ ! -f "$body" ] \
        || [ "$(wc -c <"$body" | tr -d ' ')" != "64" ] \
        || ! cmp -s "$body" <(printf 'a%.0s' $(seq 64)); then
        echo "$label /fixed preflight failed (code=$code http/$ver):" >&2
        head -c 80 "$body" 2>/dev/null >&2 || true
        echo >&2
        return 1
    fi
    echo "$label /fixed preflight ok (HTTP/2 200, 64-byte body)"
}

wait_udp() {
    local pid="$1"
    local i
    for i in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "server $pid exited before UDP ready" >&2
            return 1
        fi
        sleep 0.1
    done
}

# Remove only the dummynet pipe this harness created.
# `dnctl flush` is not a scoped operation: `flush` is a global dummynet
# state reset, and dnctl's own argument parser rejects it (it prints the
# usage summary and exits 0), so `dnctl -q flush pipe N` would either
# clear unrelated host shaping rules or silently leave pipe N configured.
# Numbered removal is `dnctl -q pipe N delete` per dnctl(8).
# The flowset/queue pair that `config plr` allocates is deliberately left
# orphaned: with no rule referencing the pipe it is inert, and its ID is
# not known here, so deleting it could remove another process's shaping.
dnctl_delete_pipe() {
    local pipe_id="$1"
    local log="${2:-/dev/null}"
    sudo -n dnctl -q pipe "$pipe_id" delete 2>>"$log" || true
}

# Resolve a dummynet anchor the loaded main ruleset will actually evaluate.
# `pfctl -a NAME -f -` alone only fills a named ruleset; those rules run only
# when a parent `dummynet-anchor` directive reaches them (pf.conf(5)). On
# macOS the default /etc/pf.conf has `dummynet-anchor "com.apple/*"`, so a
# nested `com.apple/<leaf>` is live. A top-level `bench_matrix` is not.
# Prints the anchor path on success; returns 1 when no active parent exists.
pf_active_dummynet_anchor() {
    local leaf="$1"
    local log="${2:-/dev/null}"
    local rules
    if ! rules="$(sudo -n pfctl -sr 2>>"$log")"; then
        return 1
    fi
    if printf '%s\n' "$rules" | grep -qE 'dummynet-anchor[[:space:]]+"com\.apple/\*"'; then
        printf 'com.apple/%s' "$leaf"
        return 0
    fi
    if printf '%s\n' "$rules" | grep -qE "dummynet-anchor[[:space:]]+\"${leaf}\""; then
        printf '%s' "$leaf"
        return 0
    fi
    return 1
}

# True when the named anchor currently holds at least one dummynet rule.
pf_anchor_has_dummynet() {
    local anchor="$1"
    local log="${2:-/dev/null}"
    local rules
    if ! rules="$(sudo -n pfctl -a "$anchor" -s rules 2>>"$log")"; then
        return 1
    fi
    printf '%s\n' "$rules" | grep -q dummynet
}

# Sum packets observed on a dummynet pipe (Tot_pkt and drops). Zero means
# the classifier never steered traffic into the pipe — impairment was inert.
dnctl_pipe_packet_count() {
    local pipe_id="$1"
    local log="${2:-/dev/null}"
    local out
    if ! out="$(sudo -n dnctl pipe show "$pipe_id" 2>>"$log")"; then
        printf '0'
        return 1
    fi
    printf '%s\n' "$out" | awk '
        BEGIN { n = 0 }
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\/[0-9]+$/) {
                    split($i, a, "/")
                    n += a[1] + 0
                } else if ($(i + 1) == "drops" && $i ~ /^[0-9]+$/) {
                    n += $i + 0
                } else if ($(i + 1) == "packets" && $i ~ /^[0-9]+$/) {
                    n += $i + 0
                }
            }
        }
        END { print n + 0 }
    '
}

# Print the first dummynet pipe id in [first,last] that is not already
# configured, and fail when no such id exists or the state is unknown.
#
# `dnctl pipe N config` targets an existing pipe rather than allocating a
# private one, so a fixed id would reconfigure whatever owns that pipe and
# the matching delete would then remove it. dnctl lists configured pipes as
# "%05d: <params>" (list_pipes() in sbin/ipfw/dummynet.c), and an empty
# listing means no pipes exist. dummynet_list() reports no error for a
# missing pipe, so the listing is the only usable occupancy check; when the
# output is non-empty but unparseable the caller is told skip rather than
# left to guess at an id.
dnctl_free_pipe() {
    local first="$1"
    local last="$2"
    local log="${3:-/dev/null}"
    local listing used n
    if ! listing="$(sudo -n dnctl pipe list 2>>"$log")"; then
        return 1
    fi
    used=""
    if [ -n "$listing" ]; then
        used="$(printf '%s\n' "$listing" | awk '
            /^[0-9]+:/ {
                id = $1
                sub(/:$/, "", id)
                if (id != "") printf "%s ", id + 0
            }
        ')"
        [ -n "$used" ] || return 1
    fi
    for n in $(seq "$first" "$last"); do
        case " $used " in
            *" $n "*) continue ;;
        esac
        printf '%s' "$n"
        return 0
    done
    return 1
}

# --- HTTP/2 matrix cell via h2load ---
run_h2load_cell() {
    local label="$1"
    local url="$2"
    local clients="$3"
    local streams="$4"
    local run_idx="$5"
    local server_pid="$6"
    local out="$OUT_DIR/h2/${label}_c${clients}_m${streams}_r${run_idx}.out"
    local sample="$OUT_DIR/h2/${label}_c${clients}_m${streams}_r${run_idx}.sample"

    # Drop any sample from an earlier run: if the sampler never fires, the
    # fallback below would otherwise publish a stale .sample file.
    rm -f "$sample"
    (
        sleep "$(sampler_delay)"
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
        "$url" >"$out" 2>&1
    local rc=$?
    set -e
    wait "$sampler_pid" 2>/dev/null || true
    if [ ! -f "$sample" ]; then
        sample_server "$server_pid" "$sample"
    fi

    local req_s success failed errored timedout
    req_s="$(rg -o 'finished in [^,]+, ([0-9.]+) req/s' -r '$1' "$out" | head -1 || true)"
    success="$(rg -o 'requests: .* ([0-9]+) succeeded' -r '$1' "$out" | head -1 || true)"
    failed="$(rg -o 'requests: .* ([0-9]+) failed' -r '$1' "$out" | head -1 || true)"
    errored="$(rg -o 'requests: .* ([0-9]+) errored' -r '$1' "$out" | head -1 || true)"
    timedout="$(rg -o 'requests: .* ([0-9]+) timeout' -r '$1' "$out" | head -1 || true)"
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
        | tee -a "$OUT_DIR/h2/summary.tsv"
    local cell_failed=0
    if [ "$rc" -ne 0 ]; then cell_failed=1; fi
    if [ -n "${failed:-}" ] && [ "${failed}" != "0" ]; then cell_failed=1; fi
    if [ -n "${errored:-}" ] && [ "${errored}" != "0" ]; then cell_failed=1; fi
    if [ -n "${timedout:-}" ] && [ "${timedout}" != "0" ]; then cell_failed=1; fi
    # h2load can exit 0 with an unusable summary (unsupported format or
    # zero-work duration). Require a parsed positive throughput and success
    # count before accepting the cell, matching the H3 req_s gate.
    if [ -z "${req_s:-}" ] || [ "${req_s%%.*}" = "0" ]; then cell_failed=1; fi
    if [ -z "${success:-}" ] || [ "${success}" = "0" ]; then cell_failed=1; fi
    if [ "$cell_failed" -ne 0 ]; then
        MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
        echo "matrix cell failed: h2 $label c=$clients m=$streams run=$run_idx rc=$rc req_s=${req_s:-?} succeeded=${success:-?} failed=${failed:-?} errored=${errored:-?} timeout=${timedout:-?}" >&2
    fi
}

run_h3_cell() {
    local label="$1"
    local url="$2"
    local clients="$3"
    local streams="$4"
    local run_idx="$5"
    local server_pid="$6"
    local out="$OUT_DIR/h3/${label}_c${clients}_m${streams}_r${run_idx}.out"
    local sample="$OUT_DIR/h3/${label}_c${clients}_m${streams}_r${run_idx}.sample"
    local err="$OUT_DIR/h3/${label}_c${clients}_m${streams}_r${run_idx}.err"

    # Resolve the interpreter in this shell *before* the sampler starts.
    # `$(h3_python)` would run the helper in a subshell, discard its cache
    # assignment, and re-run `pixi` after the sampler is already sleeping —
    # shifting the CPU/RSS/FD sample earlier than warmup+half-measure.
    if [ -z "${PIXI_PYTHON_H3:-}" ]; then
        PIXI_PYTHON_H3="$(cd "$ROOT" && pixi run -e "$PIXI_ENV_H3" python -c 'import sys; print(sys.executable)')"
    fi

    # Drop any sample from an earlier run: if the sampler never fires, the
    # fallback below would otherwise publish a stale .sample file.
    rm -f "$sample"
    (
        sleep "$(sampler_delay)"
        sample_server "$server_pid" "$sample"
    ) &
    local sampler_pid=$!

    set +e
    "$PIXI_PYTHON_H3" benchmarks/http3_load.py \
        --url "$url" \
        --clients "$clients" \
        --streams "$streams" \
        --warmup "$WARMUP_S" \
        --duration "$MEASURE_S" \
        >"$out" 2>"$err"
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

    printf '%s\tc=%s\tm=%s\trun=%s\treq_s=%s\tp50_us=%s\tp95_us=%s\tp99_us=%s\tok=%s\tfailed=%s\trc=%s\t%s\n' \
        "$label" "$clients" "$streams" "$run_idx" \
        "${req_s:-?}" "${p50:-?}" "${p95:-?}" "${p99:-?}" \
        "${ok:-?}" "${failed:-?}" "$rc" "$sample_line" \
        | tee -a "$OUT_DIR/h3/summary.tsv"
    local cell_failed=0
    if [ "$rc" -ne 0 ]; then cell_failed=1; fi
    if [ -n "${failed:-}" ] && [ "${failed}" != "0" ]; then cell_failed=1; fi
    if [ -z "${req_s:-}" ]; then cell_failed=1; fi
    if [ "$cell_failed" -ne 0 ]; then
        MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
        echo "matrix cell failed: h3 $label c=$clients m=$streams run=$run_idx rc=$rc failed=${failed:-?}" >&2
    fi
}

# --- H2 special scenarios (single connection) ---
# The slow and cancel cases must put the target stream and its siblings on
# one HTTP/2 connection: a server with per-connection head-of-line blocking
# or with broken RST_STREAM handling passes if the streams are split across
# connections. curl and h2load are separate processes and always use
# separate connections, so these two scenarios run through
# benchmarks/http/http2_scenarios.py (single connection, hyper-h2) instead.
# h2load still drives the throughput matrix above.
run_h2_special() {
    local label="$1"   # go|mojo
    local addr="$2"
    local server_pid="$3"
    local url="https://${addr}"
    local special_log="$OUT_DIR/special/h2_${label}.log"
    : >"$special_log"

    echo "== H2 special scenarios ($label @ $addr) ==" | tee -a "$special_log"

    local scenario line
    for scenario in slow cancel; do
        set +e
        line="$($(h2_python) benchmarks/http/http2_scenarios.py \
            --url "https://${addr}/fixed" --scenario "$scenario" --siblings 8 \
            2>>"$special_log")"
        local scenario_rc=$?
        set -e
        # A driver failure must not be recorded as a pass, and a missing
        # result line must not be recorded as a verdict at all.
        if [ -z "$line" ]; then
            line="scenario=${scenario} verdict=fail conn=single error=no-result rc=${scenario_rc}"
        fi
        echo "$line" | tee -a "$special_log"
        printf 'proto=h2 label=%s %s rc=%s\n' \
            "$label" "$line" "$scenario_rc" \
            | tee -a "$OUT_DIR/special/summary.tsv"
        case "$line" in
            *"verdict=pass"*) ;;
            *)
                MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
                echo "H2 special scenario failed: $label $scenario" >&2
                ;;
        esac
        if ! kill -0 "$server_pid" 2>/dev/null; then
            MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
            echo "H2 server exited during $label $scenario" >&2
        fi
    done

    # Loss: attempt pf/dummynet; document if unavailable (no passwordless sudo).
    local loss_note="$OUT_DIR/special/h2_${label}_loss.txt"
    local loss_verdict=skip
    local loss_detail="pf/dummynet requires root; sudo -n unavailable on this host"
    if sudo -n true 2>/dev/null; then
        # Best-effort: 5% loss via dnctl on loopback TCP to the server port.
        # Verify impairment was actually configured; otherwise a clean run
        # must not be reported as an impaired pass.
        local port="${addr##*:}"
        # Take an unused pipe id so this run cannot reconfigure or delete a
        # pipe that already belongs to another workload.
        local loss_pipe
        loss_pipe="$(dnctl_free_pipe 42 61 "$loss_note" || true)"
        if [ -z "$loss_pipe" ]; then
            loss_verdict=skip
            loss_detail="no free dummynet pipe id in 42-61; no impaired run attempted"
        else
            # Load into an anchor the main ruleset evaluates. A bare
            # top-level name (e.g. bench_matrix) can return 0 from pfctl
            # while never seeing packets.
            local loss_anchor
            loss_anchor="$(pf_active_dummynet_anchor net_mojo_bench_h2 "$loss_note" || true)"
            if [ -z "$loss_anchor" ]; then
                loss_verdict=skip
                loss_detail="no active dummynet-anchor parent (need com.apple/* or explicit leaf); no impaired run attempted"
                dnctl_delete_pipe "$loss_pipe" "$loss_note"
            else
            set +e
            sudo -n dnctl pipe "$loss_pipe" config plr 0.05 2>"$loss_note"
            local dnctl_rc=$?
            echo "dummynet in proto tcp from any to 127.0.0.1 port ${port} pipe ${loss_pipe}" \
                | sudo -n pfctl -a "$loss_anchor" -f - 2>>"$loss_note"
            local pfctl_rc=$?
            local anchor_live=0
            if pf_anchor_has_dummynet "$loss_anchor" "$loss_note"; then
                anchor_live=1
            fi
            if [ "$dnctl_rc" -ne 0 ] || [ "$pfctl_rc" -ne 0 ] \
                || [ "$anchor_live" -ne 1 ] \
                || ! command -v dnctl >/dev/null; then
                loss_verdict=skip
                loss_detail="loss impairment not configured (dnctl_rc=$dnctl_rc pfctl_rc=$pfctl_rc anchor=${loss_anchor} live=${anchor_live}); no impaired run attempted"
                sudo -n pfctl -a "$loss_anchor" -F all 2>>"$loss_note" || true
                dnctl_delete_pipe "$loss_pipe" "$loss_note"
                set -e
            else
                # Install cleanup as soon as impairment is live. RETURN
                # covers early function return; EXIT covers normal and
                # signal-driven shell exit (INT/TERM re-enter via exit so
                # EXIT runs — RETURN alone does not fire on SIGTERM).
                # Preserve the top-level server kill_pid EXIT handler.
                # shellcheck disable=SC2064
                trap "sudo -n pfctl -a ${loss_anchor} -F all 2>/dev/null || true; sudo -n dnctl -q pipe ${loss_pipe} delete 2>/dev/null || true; kill_pid \"\${GO_PID:-}\"; kill_pid \"\${MOJO_H2_PID:-}\"; kill_pid \"\${BASE_PID:-}\"; kill_pid \"\${MOJO_H3_PID:-}\"" EXIT
                # shellcheck disable=SC2064
                trap "sudo -n pfctl -a ${loss_anchor} -F all 2>/dev/null || true; sudo -n dnctl -q pipe ${loss_pipe} delete 2>/dev/null || true" RETURN
                trap 'exit 130' INT
                trap 'exit 143' TERM
                h2load --alpn-list=h2 -c 8 -m 4 -t 1 -D 5s "${url}/fixed" \
                    >"$OUT_DIR/special/h2_${label}_loss_h2load.out" 2>&1
                local loss_rc=$?
                local pipe_pkts
                pipe_pkts="$(dnctl_pipe_packet_count "$loss_pipe" "$loss_note" || true)"
                sudo -n pfctl -a "$loss_anchor" -F all 2>>"$loss_note" || true
                dnctl_delete_pipe "$loss_pipe" "$loss_note"
                trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
                trap - RETURN INT TERM
                set -e
                local loss_req loss_fail loss_success
                loss_req="$(rg -o 'finished in [^,]+, ([0-9.]+) req/s' -r '$1' \
                    "$OUT_DIR/special/h2_${label}_loss_h2load.out" | head -1 || true)"
                loss_fail="$(rg -o 'requests: .* ([0-9]+) failed' -r '$1' \
                    "$OUT_DIR/special/h2_${label}_loss_h2load.out" | head -1 || true)"
                loss_success="$(rg -o 'requests: .* ([0-9]+) succeeded' -r '$1' \
                    "$OUT_DIR/special/h2_${label}_loss_h2load.out" | head -1 || true)"
                local loss_errored loss_timeout
                loss_errored="$(rg -o 'requests: .* ([0-9]+) errored' -r '$1' \
                    "$OUT_DIR/special/h2_${label}_loss_h2load.out" | head -1 || true)"
                loss_timeout="$(rg -o 'requests: .* ([0-9]+) timeout' -r '$1' \
                    "$OUT_DIR/special/h2_${label}_loss_h2load.out" | head -1 || true)"
                # A loss run that lost every request (req_s 0.00), reported
                # failures, or exited nonzero is not a valid measurement.
                # Also reject runs where the pipe saw no packets: that means
                # the PF anchor never classified traffic despite setup rc=0.
                # Match the H2 matrix gate: require a parsed positive success
                # count so a partial/changed h2load summary cannot pass.
                local loss_ok=true
                if [ "$loss_rc" -ne 0 ]; then loss_ok=false; fi
                if [ "${loss_fail:-0}" != "0" ]; then loss_ok=false; fi
                if [ -n "${loss_errored:-}" ] && [ "$loss_errored" != "0" ]; then
                    loss_ok=false
                fi
                if [ -n "${loss_timeout:-}" ] && [ "$loss_timeout" != "0" ]; then
                    loss_ok=false
                fi
                if [ -z "$loss_req" ] || [ "${loss_req%%.*}" = "0" ]; then
                    loss_ok=false
                fi
                if [ -z "${loss_success:-}" ] || [ "$loss_success" = "0" ]; then
                    loss_ok=false
                fi
                if [ "${pipe_pkts:-0}" = "0" ]; then loss_ok=false; fi
                if ! kill -0 "$server_pid" 2>/dev/null; then loss_ok=false; fi
                if [ "$loss_ok" = "true" ]; then
                    loss_verdict=pass
                    loss_detail="dnctl plr=0.05 anchor=${loss_anchor} pipe=${loss_pipe} pipe_pkts=${pipe_pkts} req_s=${loss_req} succeeded=${loss_success} failed=${loss_fail:-?} rc=${loss_rc}"
                else
                    loss_verdict=fail
                    loss_detail="dnctl configured but load invalid anchor=${loss_anchor} pipe=${loss_pipe} pipe_pkts=${pipe_pkts:-?} rc=${loss_rc} req_s=${loss_req:-?} succeeded=${loss_success:-?} failed=${loss_fail:-?} errored=${loss_errored:-?} timeout=${loss_timeout:-?}"
                fi
            fi
            fi
        fi
    else
        echo "$loss_detail" >"$loss_note"
        # Soft stand-in: run a short clean cell and label skip (no invented loss %).
        h2load --alpn-list=h2 -c 8 -m 4 -t 1 -D 3s "${url}/fixed" \
            >"$OUT_DIR/special/h2_${label}_loss_baseline.out" 2>&1 || true
        local base_req
        base_req="$(rg -o 'finished in [^,]+, ([0-9.]+) req/s' -r '$1' \
            "$OUT_DIR/special/h2_${label}_loss_baseline.out" | head -1 || true)"
        loss_detail="${loss_detail}; no-loss reference req_s=${base_req:-?} (3s)"
    fi
    printf 'proto=h2 label=%s scenario=loss verdict=%s detail=%s\n' \
        "$label" "$loss_verdict" "$loss_detail" \
        | tee -a "$OUT_DIR/special/summary.tsv" | tee -a "$special_log"
    if [ "$loss_verdict" = "fail" ]; then
        MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
        echo "H2 special scenario failed: $label loss" >&2
    fi
}

run_h3_special() {
    local label="$1"
    local addr="$2"
    local url="https://${addr}/fixed"
    local special_log="$OUT_DIR/special/h3_${label}.log"
    : >"$special_log"
    echo "== H3 special scenarios ($label @ $addr) ==" | tee -a "$special_log"

    # Capture status under set +e so a legitimate scenario failure records
    # and continues into cancel/loss and the remaining server matrix,
    # matching the H2 special-scenario handling.
    local scenario line scenario_rc
    for scenario in slow cancel; do
        set +e
        case "$scenario" in
            slow)
                line="$($(h3_python) benchmarks/http/http3_scenarios.py \
                    --url "$url" --scenario slow --slow-s 0.25 --siblings 8 \
                    2>>"$special_log")"
                ;;
            cancel)
                line="$($(h3_python) benchmarks/http/http3_scenarios.py \
                    --url "$url" --scenario cancel --siblings 8 \
                    2>>"$special_log")"
                ;;
        esac
        scenario_rc=$?
        set -e
        if [ -z "$line" ]; then
            line="scenario=${scenario} verdict=fail error=no-result rc=${scenario_rc}"
        fi
        echo "$line" | tee -a "$special_log"
        printf 'proto=h3 label=%s %s rc=%s\n' \
            "$label" "$line" "$scenario_rc" \
            | tee -a "$OUT_DIR/special/summary.tsv"
        case "$line" in
            *"verdict=pass"*) ;;
            *)
                MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
                echo "H3 special scenario failed: $label $scenario" >&2
                ;;
        esac
    done

    # Loss: try pf first; always also run client-side drop (measurable without root).
    local loss_pf_verdict=skip
    local loss_pf_detail="sudo -n unavailable"
    local loss_pipe=""
    if sudo -n true 2>/dev/null; then
        local port="${addr##*:}"
        local pf_note="$OUT_DIR/special/h3_${label}_pf.txt"
        # Take an unused pipe id so this run cannot reconfigure or delete a
        # pipe that already belongs to another workload. The H2 range stops
        # at 61 so a concurrent harness run cannot land on the same id.
        loss_pipe="$(dnctl_free_pipe 62 81 "$pf_note" || true)"
        if [ -z "$loss_pipe" ]; then
            loss_pf_detail="no free dummynet pipe id in 62-81"
        else
            local loss_anchor
            loss_anchor="$(pf_active_dummynet_anchor net_mojo_bench_h3 "$pf_note" || true)"
            if [ -z "$loss_anchor" ]; then
                loss_pf_detail="no active dummynet-anchor parent (need com.apple/* or explicit leaf)"
                dnctl_delete_pipe "$loss_pipe" "$pf_note"
                loss_pipe=""
            else
            set +e
            sudo -n dnctl pipe "$loss_pipe" config plr 0.05 \
                >"$pf_note" 2>&1
            local dnctl_rc=$?
            echo "dummynet in proto udp from any to 127.0.0.1 port ${port} pipe ${loss_pipe}" \
                | sudo -n pfctl -a "$loss_anchor" -f - \
                >>"$pf_note" 2>&1
            local pfctl_rc=$?
            local anchor_live=0
            if pf_anchor_has_dummynet "$loss_anchor" "$pf_note"; then
                anchor_live=1
            fi
            set -e
            # Do not claim configured when either step failed (e.g. PF
            # disabled) or the parent anchor is inert; match H2 checks.
            if [ "$dnctl_rc" -ne 0 ] || [ "$pfctl_rc" -ne 0 ] \
                || [ "$anchor_live" -ne 1 ]; then
                loss_pf_verdict=skip
                loss_pf_detail="loss impairment not configured (dnctl_rc=$dnctl_rc pfctl_rc=$pfctl_rc anchor=${loss_anchor} live=${anchor_live})"
                sudo -n pfctl -a "$loss_anchor" -F all 2>>"$pf_note" || true
                dnctl_delete_pipe "$loss_pipe" "$pf_note"
                loss_pipe=""
            else
                loss_pf_verdict=configured
                loss_pf_detail="dnctl udp plr=0.05 on port ${port} pipe ${loss_pipe} anchor=${loss_anchor}"
                # RETURN for early return; EXIT+INT/TERM for signal kill.
                # shellcheck disable=SC2064
                trap "sudo -n pfctl -a ${loss_anchor} -F all 2>/dev/null || true; sudo -n dnctl -q pipe ${loss_pipe} delete 2>/dev/null || true; kill_pid \"\${GO_PID:-}\"; kill_pid \"\${MOJO_H2_PID:-}\"; kill_pid \"\${BASE_PID:-}\"; kill_pid \"\${MOJO_H3_PID:-}\"" EXIT
                # shellcheck disable=SC2064
                trap "sudo -n pfctl -a ${loss_anchor} -F all 2>/dev/null || true; sudo -n dnctl -q pipe ${loss_pipe} delete 2>/dev/null || true" RETURN
                trap 'exit 130' INT
                trap 'exit 143' TERM
            fi
            fi
        fi
    fi
    printf 'proto=h3 label=%s scenario=loss_pf verdict=%s detail=%s\n' \
        "$label" "$loss_pf_verdict" "$loss_pf_detail" \
        | tee -a "$OUT_DIR/special/summary.tsv" | tee -a "$special_log"

    # Tear down PF before the client-side drop run so the recorded
    # method=client_datagram_drop measures standalone 5% client loss,
    # not combined kernel + client loss.
    if [ "$loss_pf_verdict" = "configured" ]; then
        sudo -n pfctl -a "$loss_anchor" -F all 2>/dev/null || true
        dnctl_delete_pipe "$loss_pipe" /dev/null
        trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
        trap - RETURN INT TERM
        loss_pf_verdict=cleaned
    fi

    set +e
    line="$($(h3_python) benchmarks/http/http3_scenarios.py \
        --url "$url" --scenario loss --drop-rate 0.05 \
        --clients 4 --streams 4 --duration 5 \
        2>>"$special_log")"
    scenario_rc=$?
    set -e
    if [ -z "$line" ]; then
        line="scenario=loss verdict=fail error=no-result rc=${scenario_rc}"
    fi
    echo "$line" | tee -a "$special_log"
    printf 'proto=h3 label=%s %s method=client_datagram_drop rc=%s\n' \
        "$label" "$line" "$scenario_rc" \
        | tee -a "$OUT_DIR/special/summary.tsv"
    case "$line" in
        *"verdict=pass"*) ;;
        *)
            MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
            echo "H3 special scenario failed: $label loss" >&2
            ;;
    esac
}

# ========== HTTP/2 matrix ==========
: >"$OUT_DIR/h2/summary.tsv"
echo -e "label\tc\tm\trun\treq_s\tp50_us\tp95_us\tp99_us\tsucceeded\tfailed\trc\tsamples" \
    >>"$OUT_DIR/h2/summary.tsv"
: >"$OUT_DIR/special/summary.tsv"

if [ "${SKIP_H2:-0}" != "1" ]; then
    if ! command -v h2load >/dev/null; then
        echo "h2load not found; install with: brew install nghttp2" >&2
        exit 1
    fi
    for artifact in build/tls/test-cert.pem build/tls/test-key.pem; do
        [ -f "$artifact" ] || {
            echo "missing $artifact; run tls-build" >&2
            exit 1
        }
    done
    if [ "${SKIP_MOJO:-0}" != "1" ]; then
        for artifact in build/tls/libnet_tls build/http2/libnet_hpack; do
            [ -f "$artifact" ] || {
                echo "missing $artifact; run tls-build + hpack-test (or SKIP_MOJO=1 for Go-only)" >&2
                exit 1
            }
        done
    fi

    if [ "${SKIP_GO:-0}" != "1" ]; then
        echo "== build Go HTTPS+H2 =="
        # GO_BIN may already be absolute when OUT_DIR is overridden.
        go_bin="$GO_BIN"
        case "$go_bin" in
            /*) ;;
            *) go_bin="$ROOT/$go_bin" ;;
        esac
        go -C benchmarks/http_go build -o "$go_bin" .
        GOMAXPROCS=1 "$GO_BIN" -tls -addr "$GO_ADDR" \
            -cert build/tls/test-cert.pem -key build/tls/test-key.pem \
            >"$OUT_DIR/h2/go_server.log" 2>&1 &
        GO_PID=$!
        trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
        wait_listen "$GO_ADDR" "$GO_PID"
        verify_fixed_h2 "go" "$GO_ADDR"
        for clients in $CONNS; do
            for streams in $STREAMS; do
                for run in $(seq 1 "$RUNS"); do
                    echo "== Go H2 GET /fixed c=${clients} m=${streams} run=${run} =="
                    run_h2load_cell "go" "https://${GO_ADDR}/fixed" "$clients" "$streams" "$run" "$GO_PID"
                done
            done
        done
        if [ "${SKIP_SPECIAL:-0}" != "1" ]; then
            run_h2_special "go" "$GO_ADDR" "$GO_PID"
        fi
        kill_pid "$GO_PID"
        GO_PID=
    fi

    if [ "${SKIP_MOJO:-0}" != "1" ]; then
        echo "== build Mojo HTTPS+H2 =="
        pixi run -e "$PIXI_ENV_H2" mojo build --Werror -I . \
            benchmarks/http2_tls_server.mojo -o "$MOJO_H2_BIN"
        "$MOJO_H2_BIN" >"$OUT_DIR/h2/mojo_server.log" 2>&1 &
        MOJO_H2_PID=$!
        trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
        wait_listen "$MOJO_H2_ADDR" "$MOJO_H2_PID"
        verify_fixed_h2 "mojo" "$MOJO_H2_ADDR"
        for clients in $CONNS; do
            for streams in $STREAMS; do
                for run in $(seq 1 "$RUNS"); do
                    echo "== Mojo H2 GET /fixed c=${clients} m=${streams} run=${run} =="
                    run_h2load_cell "mojo" "https://${MOJO_H2_ADDR}/fixed" "$clients" "$streams" "$run" "$MOJO_H2_PID"
                done
            done
        done
        if [ "${SKIP_SPECIAL:-0}" != "1" ]; then
            run_h2_special "mojo" "$MOJO_H2_ADDR" "$MOJO_H2_PID"
        fi
        kill_pid "$MOJO_H2_PID"
        MOJO_H2_PID=
    fi
fi

# ========== HTTP/3 matrix ==========
: >"$OUT_DIR/h3/summary.tsv"
echo -e "label\tc\tm\trun\treq_s\tp50_us\tp95_us\tp99_us\tok\tfailed\trc\tsamples" \
    >>"$OUT_DIR/h3/summary.tsv"

if [ "${SKIP_H3:-0}" != "1" ]; then
    for artifact in build/tls/test-cert.pem build/tls/test-key.pem; do
        [ -f "$artifact" ] || {
            echo "missing $artifact; run tls-build" >&2
            exit 1
        }
    done
    if [ "${SKIP_MOJO:-0}" != "1" ]; then
        [ -f build/quic/libnet_quic_provider ] || {
            echo "missing build/quic/libnet_quic_provider; run quic-build (or SKIP_MOJO=1 for baseline-only)" >&2
            exit 1
        }
    fi

    if [ "${SKIP_BASELINE:-0}" != "1" ]; then
        echo "== start aioquic H3 baseline =="
        $(h3_python) benchmarks/http3_aioquic_baseline.py \
            --host 127.0.0.1 --port 18452 \
            --certificate build/tls/test-cert.pem \
            --private-key build/tls/test-key.pem \
            >"$OUT_DIR/h3/baseline_server.log" 2>&1 &
        BASE_PID=$!
        trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
        wait_udp "$BASE_PID"
        sleep 0.5
        for clients in $CONNS; do
            for streams in $STREAMS; do
                for run in $(seq 1 "$RUNS"); do
                    echo "== aioquic H3 GET /fixed c=${clients} m=${streams} run=${run} =="
                    run_h3_cell "aioquic" "https://${BASELINE_H3_ADDR}/fixed" \
                        "$clients" "$streams" "$run" "$BASE_PID"
                done
            done
        done
        if [ "${SKIP_SPECIAL:-0}" != "1" ]; then
            run_h3_special "aioquic" "$BASELINE_H3_ADDR"
        fi
        kill_pid "$BASE_PID"
        BASE_PID=
    fi

    if [ "${SKIP_MOJO:-0}" != "1" ]; then
        echo "== build Mojo H3 =="
        pixi run -e "$PIXI_ENV_H3" mojo build --Werror -I . \
            benchmarks/http3_server.mojo -o "$MOJO_H3_BIN"
        "$MOJO_H3_BIN" >"$OUT_DIR/h3/mojo_server.log" 2>&1 &
        MOJO_H3_PID=$!
        trap 'kill_pid "${GO_PID:-}"; kill_pid "${MOJO_H2_PID:-}"; kill_pid "${BASE_PID:-}"; kill_pid "${MOJO_H3_PID:-}"' EXIT
        wait_udp "$MOJO_H3_PID"
        sleep 0.5
        for clients in $CONNS; do
            for streams in $STREAMS; do
                for run in $(seq 1 "$RUNS"); do
                    echo "== Mojo H3 GET /fixed c=${clients} m=${streams} run=${run} =="
                    run_h3_cell "mojo" "https://${MOJO_H3_ADDR}/fixed" \
                        "$clients" "$streams" "$run" "$MOJO_H3_PID"
                done
            done
        done
        if [ "${SKIP_SPECIAL:-0}" != "1" ]; then
            run_h3_special "mojo" "$MOJO_H3_ADDR"
        fi
        kill_pid "$MOJO_H3_PID"
        MOJO_H3_PID=
    fi
fi

echo
echo "== H2 summary =="
column -t -s $'\t' "$OUT_DIR/h2/summary.tsv" 2>/dev/null || cat "$OUT_DIR/h2/summary.tsv"
echo
echo "== H3 summary =="
column -t -s $'\t' "$OUT_DIR/h3/summary.tsv" 2>/dev/null || cat "$OUT_DIR/h3/summary.tsv"
echo
echo "== Special scenarios =="
cat "$OUT_DIR/special/summary.tsv"
if [ "$MATRIX_FAILURES" -gt 0 ]; then
    echo "$MATRIX_FAILURES matrix cell(s) failed" >&2
    exit 1
fi

# Aggregate means for README convenience
python3 - "$OUT_DIR" <<'PY'
import collections, statistics, sys
from pathlib import Path
out = Path(sys.argv[1])

def cell_num(s):
    s = s or ""
    if "=" in s:
        s = s.split("=", 1)[1]
    return float(s)

def means(path):
    if not path.exists():
        return
    lines = path.read_text().strip().splitlines()
    if len(lines) < 2:
        return
    hdr = lines[0].split("\t")
    rows = []
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) < 4:
            continue
        d = dict(zip(hdr, cols))
        label = d.get("label", cols[0])
        try:
            c = int(cell_num(d.get("c", cols[1])))
            m = int(cell_num(d.get("m", cols[2])))
            req = cell_num(d.get("req_s", ""))
            p50 = cell_num(d.get("p50_us", ""))
            p95 = cell_num(d.get("p95_us", ""))
            p99 = cell_num(d.get("p99_us", ""))
        except ValueError:
            continue
        rows.append(
            {
                "label": label,
                "c": c,
                "m": m,
                "req_s": req,
                "p50": p50,
                "p95": p95,
                "p99": p99,
            }
        )
    groups = collections.defaultdict(list)
    for r in rows:
        groups[(r["label"], r["c"], r["m"])].append(r)
    print(f"\n== means ({path.name}) ==")
    for key in sorted(groups, key=lambda k: (k[0], k[1], k[2])):
        g = groups[key]

        def avg(field):
            vals = [x[field] for x in g if x[field] == x[field]]
            return statistics.fmean(vals) if vals else float("nan")

        print(
            f"{key[0]}\tc={key[1]}\tm={key[2]}\tn={len(g)}\t"
            f"req_s={avg('req_s'):.1f}\tp50={avg('p50'):.0f}\t"
            f"p95={avg('p95'):.0f}\tp99={avg('p99'):.0f}"
        )

means(out / "h2" / "summary.tsv")
means(out / "h3" / "summary.tsv")
PY
