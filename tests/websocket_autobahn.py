#!/usr/bin/env python3
"""Run pinned upstream noncompression conformance against our loopback fixture."""
from __future__ import annotations

import argparse
import ast
import json
import platform
import re
from pathlib import Path
import subprocess
import tempfile

from test_http_websocket_interop import ROOT, fixture

IMAGE = "crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074"
SOURCE_REVISION = "6ed6f439dc7ed0d7432fe2cf7481b110905ecc5c"
DEFAULT_CASES = [f"{group}.*" for group in range(1, 8)] + ["9.*"]


def scheduled_cases(output: str) -> set[str]:
    matches = re.findall(r"^Cases = (\[.*\])$", output, re.MULTILINE)
    if len(matches) != 1:
        raise AssertionError("Autobahn did not report one scheduled case list")
    cases = ast.literal_eval(matches[0])
    if not isinstance(cases, list) or not cases or any(not isinstance(case, str) for case in cases):
        raise AssertionError("Autobahn scheduled case list is empty or invalid")
    if len(set(cases)) != len(cases):
        raise AssertionError("Autobahn scheduled duplicate cases")
    return set(cases)


def validate_reports(reports: Path, expected: set[str]) -> int:
    index = json.loads((reports / "index.json").read_text())
    agent = index.get("net-mojo", {})
    if not agent:
        raise AssertionError("Autobahn produced no net-mojo results")
    missing = expected - agent.keys()
    unexpected = agent.keys() - expected
    if missing or unexpected:
        raise AssertionError(f"Autobahn incomplete coverage: missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    failed = []
    for case, result in agent.items():
        for key in ("behavior", "behaviorClose"):
            value = result.get(key)
            if value not in ("OK", "INFORMATIONAL"):
                failed.append(f"{case}: {key}={value}")
    if failed:
        raise AssertionError("Autobahn conformance failures:\n" + "\n".join(failed))
    return len(agent)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", nargs="+", default=DEFAULT_CASES)
    parser.add_argument("--reports", default="build/websocket-autobahn")
    args = parser.parse_args()
    report_root = (ROOT / args.reports).resolve()
    report_root.mkdir(parents=True, exist_ok=True)
    reports = Path(tempfile.mkdtemp(prefix="run-", dir=report_root))
    config_root = ROOT / "build/websocket-autobahn-config"
    config_root.mkdir(parents=True, exist_ok=True)
    config_dir = Path(tempfile.mkdtemp(prefix="run-", dir=config_root))
    with fixture(conformance=True) as port:
        host = "127.0.0.1" if platform.system() == "Linux" else "host.docker.internal"
        spec = {
            "outdir": "/reports",
            "servers": [{"url": f"ws://{host}:{port}/echo", "agent": "net-mojo"}],
            "cases": args.cases,
            "exclude-cases": ["12.*", "13.*"],
            "exclude-agent-cases": {},
        }
        config = config_dir / "fuzzingclient.json"
        config.write_text(json.dumps(spec, indent=2) + "\n")
        command = ["docker", "run", "--rm", "--platform", "linux/amd64"]
        if platform.system() == "Linux":
            command += ["--network", "host"]
        command += ["--volume", f"{config_dir}:/config:ro", "--volume", f"{reports}:/reports",
                    IMAGE, "wstest", "--mode", "fuzzingclient", "--spec", "/config/fuzzingclient.json"]
        result = subprocess.run(command, check=True, timeout=2400, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (reports / "upstream.log").write_text(result.stdout)
        print(result.stdout, end="")
    count = validate_reports(reports, scheduled_cases(result.stdout))
    print(f"PASS Autobahn {count} noncompression cases; reports={reports}; image={IMAGE}; source={SOURCE_REVISION}")


if __name__ == "__main__":
    main()
