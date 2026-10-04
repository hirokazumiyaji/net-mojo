#!/usr/bin/env python3
"""Integration checks in the dedicated, disconnected NET_ADMIN container."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "benchmarks/http/linux_netem.py"


class LinuxNetemTests(unittest.TestCase):
    def run_workload(self, *command, loss=0):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            result = subprocess.run([
                sys.executable, str(SCRIPT), "--delay-ms", "10",
                "--loss-percent", str(loss), "--output", str(output),
                "--", *command,
            ], capture_output=True, text=True)
            return result, json.loads(output.read_text())

    def test_real_round_trip_delay_and_cleanup(self):
        command = """
import json, socket, threading, time
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(('127.0.0.1', 0))
def echo():
    for _ in range(4):
        data, address = server.recvfrom(64)
        server.sendto(data, address)
worker = threading.Thread(target=echo)
worker.start()
client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
client.settimeout(2)
samples = []
for _ in range(4):
    start = time.perf_counter()
    client.sendto(b'roundtrip', server.getsockname())
    assert client.recvfrom(64)[0] == b'roundtrip'
    samples.append((time.perf_counter() - start) * 1000)
worker.join()
print(json.dumps(samples))
"""
        result, evidence = self.run_workload(sys.executable, "-c", command)
        self.assertEqual(result.returncode, 0, result.stderr)
        samples = json.loads(result.stdout)
        self.assertEqual(len(samples), 4)
        self.assertTrue(all(sample >= 18 for sample in samples), samples)
        self.assertEqual(evidence["configured"][0]["kind"], "netem")
        self.assertTrue(all(q["kind"] == "noqueue" for q in evidence["after_cleanup"]))

    def test_nonzero_packet_drop_counters(self):
        command = [sys.executable, "-c", (
            "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
            "[s.sendto(b'x'*64,('127.0.0.1',23456)) for _ in range(1000)]; "
            "import time; time.sleep(.2)"
        )]
        result, evidence = self.run_workload(*command, loss=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(evidence["after_workload"][0]["drops"], 0)
        self.assertTrue(all(q["kind"] == "noqueue" for q in evidence["after_cleanup"]))

    def test_failed_workload_preserves_exit_status_and_cleans_up(self):
        result, evidence = self.run_workload(sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(evidence["exit_code"], 7)
        self.assertTrue(all(q["kind"] == "noqueue" for q in evidence["after_cleanup"]))

    def test_existing_qdisc_is_preserved(self):
        subprocess.run(["tc", "qdisc", "add", "dev", "lo", "root", "handle", "43:",
                        "netem", "delay", "1ms"], check=True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([
                    sys.executable, str(SCRIPT), "--delay-ms", "10",
                    "--loss-percent", "1", "--output", f"{directory}/result.json",
                    "--", "true",
                ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to replace", result.stderr)
            state = json.loads(subprocess.check_output(["tc", "-j", "qdisc", "show", "dev", "lo"]))
            self.assertEqual(state[0]["handle"], "43:")
        finally:
            subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root", "handle", "43:"], check=True)

    def test_active_external_interface_is_refused(self):
        subprocess.run(["ip", "link", "add", "netem-test", "type", "dummy"], check=True)
        try:
            subprocess.run(["ip", "link", "set", "netem-test", "up"], check=True)
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([
                    sys.executable, str(SCRIPT), "--delay-ms", "10",
                    "--loss-percent", "1", "--output", f"{directory}/result.json",
                    "--", "true",
                ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("disconnect all container networks", result.stderr)
            state = json.loads(subprocess.check_output(["tc", "-j", "qdisc", "show", "dev", "lo"]))
            self.assertTrue(all(q["kind"] == "noqueue" for q in state))
        finally:
            subprocess.run(["ip", "link", "del", "netem-test"], check=True)

    def test_termination_stops_workload_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            pid_file = Path(directory) / "workload.pid"
            process = subprocess.Popen([
                sys.executable, str(SCRIPT), "--delay-ms", "10",
                "--loss-percent", "0", "--output", str(output), "--",
                sys.executable, "-c", (
                    "import os,pathlib,time; "
                    f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                    "time.sleep(30)"
                ),
            ])
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists())
                workload_pid = int(pid_file.read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=6), 143)
                with self.assertRaises(ProcessLookupError):
                    os.kill(workload_pid, 0)
                evidence = json.loads(output.read_text())
                self.assertTrue(all(q["kind"] == "noqueue" for q in evidence["after_cleanup"]))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=6)


if __name__ == "__main__":
    unittest.main()
