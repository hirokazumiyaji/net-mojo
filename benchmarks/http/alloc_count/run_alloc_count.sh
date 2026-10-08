#!/usr/bin/env bash
# Count libc malloc/free calls per request against the Mojo HTTP/1 server and
# Go memstats baseline. Must run inside the Linux container documented in
# LINUX_NETWORK.md. Builds the LD_PRELOAD shim here with cc.
set -eu

ROOT="${ROOT:-/work}"
OUT_DIR="${OUT_DIR:-$ROOT/build/bench/u111/alloc}"
MOJO_BIN="${MOJO_BIN:-$ROOT/build/bench/u111/http1_server}"
GO_MEMSTATS_BIN="${GO_MEMSTATS_BIN:-$ROOT/build/bench/u111/go_memstats_server}"
HTTP_LOAD_BIN="${HTTP_LOAD_BIN:-$ROOT/build/bench/u111/http-load}"
SHIM_SRC="${SHIM_SRC:-$ROOT/benchmarks/http/alloc_count/malloc_count.c}"
SHIM_SO="${SHIM_SO:-$OUT_DIR/libmalloc_count.so}"
REQUESTS="${REQUESTS:-10000}"
RATE="${RATE:-1000}"
WARMUP_S="${WARMUP_S:-3}"
CONNECTIONS="${CONNECTIONS:-32}"
MOJO_ADDR="${MOJO_ADDR:-127.0.0.1:18081}"
GO_ADDR="${GO_ADDR:-127.0.0.1:19080}"

mkdir -p "$OUT_DIR"
cc -O2 -fPIC -shared -o "$SHIM_SO" "$SHIM_SRC" -ldl

wait_listen() {
    local addr="$1"
    local host="${addr%:*}" port="${addr##*:}"
    for _ in $(seq 1 50); do
        if python3 -c "import socket;s=socket.socket();s.settimeout(0.2);s.connect(('$host',$port));s.close()" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

http_get() {
    python3 -c '
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=3) as r:
    sys.stdout.write(r.read().decode())
' "$1"
}

terminate_pid() {
    local pid=$1
    kill -TERM $pid 2>/dev/null || true
    for _ in $(seq 1 50); do
        if ! kill -0 $pid 2>/dev/null; then break; fi
        sleep 0.1
    done
    kill -KILL $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    sleep 1
}

run_mojo() {
    local mojo_counts="$OUT_DIR/mojo_alloc.json"
    rm -f "$mojo_counts"
    MALLOC_COUNT_OUTPUT="$mojo_counts" LD_PRELOAD="$SHIM_SO" taskset -c 0 "$MOJO_BIN" \
        > "$OUT_DIR/mojo_server.log" 2>&1 &
    local pid=$!
    wait_listen "$MOJO_ADDR" || { terminate_pid $pid; return 1; }
    taskset -c 1,2 "$HTTP_LOAD_BIN" -url "http://$MOJO_ADDR/fixed" \
        -connections "$CONNECTIONS" -warmup 0 -duration "${WARMUP_S}s" \
        > "$OUT_DIR/mojo_warmup.json" 2>&1 || true
    kill -USR1 $pid
    sleep 0.2
    local dur=$((REQUESTS / RATE))
    taskset -c 1,2 "$HTTP_LOAD_BIN" -url "http://$MOJO_ADDR/fixed" \
        -connections "$CONNECTIONS" -warmup 0 -rate "$RATE" -duration "${dur}s" \
        > "$OUT_DIR/mojo_load.json" 2>&1
    kill -USR2 $pid
    sleep 0.2
    terminate_pid $pid
}

run_go() {
    local pre="$OUT_DIR/go_memstats_pre.json"
    local post="$OUT_DIR/go_memstats_post.json"
    taskset -c 0 "$GO_MEMSTATS_BIN" -addr "$GO_ADDR" \
        > "$OUT_DIR/go_memstats_server.log" 2>&1 &
    local pid=$!
    wait_listen "$GO_ADDR" || { terminate_pid $pid; return 1; }
    taskset -c 1,2 "$HTTP_LOAD_BIN" -url "http://$GO_ADDR/fixed" \
        -connections "$CONNECTIONS" -warmup 0 -duration "${WARMUP_S}s" \
        > "$OUT_DIR/go_warmup.json" 2>&1 || true
    http_get "http://$GO_ADDR/_memstats" > "$pre"
    local dur=$((REQUESTS / RATE))
    taskset -c 1,2 "$HTTP_LOAD_BIN" -url "http://$GO_ADDR/fixed" \
        -connections "$CONNECTIONS" -warmup 0 -rate "$RATE" -duration "${dur}s" \
        > "$OUT_DIR/go_load.json" 2>&1
    http_get "http://$GO_ADDR/_memstats" > "$post"
    terminate_pid $pid
}

echo "=== alloc-count Mojo ==="
run_mojo
echo "=== alloc-count Go ==="
run_go

python3 - "$OUT_DIR" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
mojo = json.loads((out / "mojo_alloc.json").read_text())
mojo_load = json.loads((out / "mojo_load.json").read_text())
pre = json.loads((out / "go_memstats_pre.json").read_text())
post = json.loads((out / "go_memstats_post.json").read_text())
go_load = json.loads((out / "go_load.json").read_text())

def _success(label: str, data: dict) -> int:
    for key in ("samples", "success"):
        if key in data:
            return int(data[key])
    raise SystemExit(
        f"{label} load output missing both 'samples' and 'success' fields"
    )

mojo_success = _success("mojo", mojo_load)
go_success = _success("go", go_load)

mojo_total_calls = sum(v for k, v in mojo.items() if k.endswith("_calls") and k != "free_calls")
mojo_total_bytes = sum(v for k, v in mojo.items() if k.endswith("_bytes"))

delta_mallocs = int(post["mallocs"]) - int(pre["mallocs"])
delta_frees = int(post["frees"]) - int(pre["frees"])
delta_bytes = int(post["total_alloc"]) - int(pre["total_alloc"])

report = {
    "requests_mojo": mojo_success,
    "requests_go": go_success,
    "mojo_libc": {
        "raw": mojo,
        "total_alloc_calls": mojo_total_calls,
        "total_alloc_bytes": mojo_total_bytes,
        "allocs_per_request": mojo_total_calls / mojo_success if mojo_success else 0,
        "bytes_per_request": mojo_total_bytes / mojo_success if mojo_success else 0,
        "free_calls": int(mojo["free_calls"]),
    },
    "go_runtime": {
        "mallocs_delta": delta_mallocs,
        "frees_delta": delta_frees,
        "total_alloc_bytes_delta": delta_bytes,
        "allocs_per_request": delta_mallocs / go_success if go_success else 0,
        "bytes_per_request": delta_bytes / go_success if go_success else 0,
    },
}
(out / "alloc_report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
PY
