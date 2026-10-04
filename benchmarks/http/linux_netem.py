#!/usr/bin/env python3
"""Run a benchmark with packet delay/loss in a disconnected Docker namespace."""

import argparse
import json
import math
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys


def tc_state():
    return json.loads(subprocess.check_output(["tc", "-s", "-j", "qdisc", "show", "dev", "lo"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delay-ms", type=float, required=True)
    parser.add_argument("--loss-percent", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a benchmark command is required")
    if not math.isfinite(args.delay_ms) or args.delay_ms < 0:
        parser.error("delay must be finite and nonnegative")
    if not math.isfinite(args.loss_percent) or not 0 <= args.loss_percent <= 100:
        parser.error("loss must be between 0 and 100 percent")
    if platform.system() != "Linux" or not Path("/.dockerenv").exists():
        parser.error("run inside the dedicated Docker container")
    links = json.loads(subprocess.check_output(["ip", "-j", "link", "show"]))
    if {link["ifname"] for link in links if "UP" in link["flags"]} != {"lo"}:
        parser.error("disconnect all container networks before shaping loopback")
    before = tc_state()
    if any(qdisc["kind"] != "noqueue" for qdisc in before):
        parser.error("loopback already has a qdisc; refusing to replace it")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    evidence = {
        "host": platform.uname()._asdict(),
        "command": command,
        "delay_ms_per_direction": args.delay_ms,
        "loss_percent_per_direction": args.loss_percent,
        "before": before,
    }
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    # Defer interruption until ownership of the new qdisc is recorded.
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    installed = False
    process = None
    try:
        subprocess.run([
            "tc", "qdisc", "add", "dev", "lo", "root", "handle", "42:",
            "netem", "delay", f"{args.delay_ms}ms", "loss", f"{args.loss_percent}%",
            "limit", "100000",
        ], check=True)
        installed = True
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        evidence["configured"] = tc_state()
        process = subprocess.Popen(command, start_new_session=True)
        evidence["exit_code"] = process.wait()
        return evidence["exit_code"]
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        try:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        finally:
            try:
                if installed:
                    try:
                        evidence["after_workload"] = tc_state()
                    finally:
                        subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root", "handle", "42:"], check=True)
                        evidence["after_cleanup"] = tc_state()
                        args.output.write_text(json.dumps(evidence, indent=2) + "\n")
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


if __name__ == "__main__":
    sys.exit(main())
