#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PYCONFIG'
import hashlib
import json
from pathlib import Path
source = Path("net/quic/provider/src/lib.rs").read_text()
helper = source.split("fn apply_provider_quic_transport_settings", 1)[1].split("\n}", 1)[0]
fixture = Path("diagnostics/active_quic_memory/probe.rs").read_text()
for call in (
    "set_initial_max_data(10_000_000)",
    "set_initial_max_stream_data_bidi_local(1_000_000)",
    "set_initial_max_stream_data_bidi_remote(1_000_000)",
    "set_initial_max_stream_data_uni(1_000_000)",
    "set_initial_max_streams_bidi(100)", "set_initial_max_streams_uni(3)",
):
    assert call in fixture, f"historical diagnostic configuration changed: {call}"
assert "set_max_connection_window" not in fixture
assert "set_max_stream_window" not in fixture
print(json.dumps({
    "allocation_fixture_flow_profile": "historical 10M connection / 1M initial streams / 100 bidi / 3 uni",
    "provider_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
    "provider_transport_helper_sha256": hashlib.sha256(helper.encode()).hexdigest(),
    "provider_transport_helper": helper.strip(),
}))
PYCONFIG
quiche_source=$(bash scripts/prepare_quiche_source.sh)
cat diagnostics/active_quic_memory/range_probe.rs >> "$quiche_source/src/range_buf.rs"
cat diagnostics/active_quic_memory/recv_probe.rs >> "$quiche_source/src/stream/recv_buf.rs"
printf '\n#[cfg(test)]\npub(crate) use recv_buf::RecvBuf;\n' >> "$quiche_source/src/stream/mod.rs"
cat diagnostics/active_quic_memory/probe.rs >> "$quiche_source/src/lib.rs"
cargo test --locked --release --manifest-path "$quiche_source/Cargo.toml" \
    --target-dir build/quic/diagnostic-cargo active_receive_allocation_diagnostic \
    -- --nocapture --test-threads=1
