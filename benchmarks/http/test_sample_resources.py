import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import sample_resources as sampler


@contextlib.contextmanager
def owned_child(limited=False):
    code = '''
import resource,sys,tempfile,time
if sys.argv[1]=="True": resource.setrlimit(resource.RLIMIT_NOFILE,(64,64))
files=[]
body=None
print("ready",flush=True)
for command in sys.stdin:
    if command.strip()=="grow":
        body=bytearray(8<<20)
        for index in range(0,len(body),4096): body[index]=1
        files=[tempfile.TemporaryFile() for _ in range(16)]
        end=time.monotonic()+.2
        while time.monotonic()<end: value=sum(range(100))
    elif command.strip()=="limit":
        resource.setrlimit(resource.RLIMIT_NOFILE,(32,64))
    else:
        for item in files: item.close()
        files=[]
        body=None
    print("done",flush=True)
'''
    child = subprocess.Popen([sys.executable, "-u", "-c", code, str(limited)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        assert child.stdout.readline().strip() == "ready"
        yield child
    finally:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=3)
        child.stdin.close()
        child.stdout.close()


class ResourceTests(unittest.TestCase):
    def test_linux_fd_limit_formats_and_required_metadata(self):
        for soft, hard, expected in [("64", "128", (64, 128)), ("64", "unlimited", (64, "unlimited")),
                                     ("unlimited", "unlimited", ("unlimited", "unlimited"))]:
            text = "Limit                     Soft Limit           Hard Limit           Units\n"
            text += f"Max open files            {soft}                   {hard}                  files\n"
            self.assertEqual(sampler._linux_fd_limits(text), expected)
        for text in ("Max processes 64 128 processes\n", "Max open files unknown 128 files\n"):
            with self.assertRaises(ValueError): sampler._linux_fd_limits(text)

    def test_real_child_limit_changes_are_sampled(self):
        with owned_child(limited=True) as child, sampler.Process(child.pid, "server") as process:
            initial = process.sample()
            self.assertEqual(initial["state"], "running")
            expected = (64, 64, "proc_limits") if sys.platform == "linux" else (None, None, "not_exposed")
            self.assertEqual(tuple(initial[field] for field in ("fd_limit_soft", "fd_limit_hard", "fd_limit_source")), expected)
            child.stdin.write("limit\n"); child.stdin.flush()
            self.assertEqual(child.stdout.readline().strip(), "done")
            changed = process.sample()
            self.assertEqual(changed["state"], "running")
            self.assertEqual(changed["start_token"], initial["start_token"])
            expected = (32, 64, "proc_limits") if sys.platform == "linux" else (None, None, "not_exposed")
            self.assertEqual(tuple(changed[field] for field in ("fd_limit_soft", "fd_limit_hard", "fd_limit_source")), expected)

    def test_numeric_resource_formats_preserve_units(self):
        for text, seconds in [("0:00.07", .07), ("12:03.5", 723.5), ("2:03:04.50", 7384.5), ("1-02:03:04.50", 93784.5)]:
            self.assertEqual(sampler._cpu_time(text), seconds)
        self.assertEqual(sampler._numeric_fds("p42\nfcwd\nftxt\nf0\nf1\nf16\nf1\n"), 3)
        stat = "42 (worker) busy) R " + " ".join(str(i) for i in range(1, 23))
        self.assertEqual(sampler._linux_stat(stat), (23, "19"))
        self.assertEqual(sampler._linux_rss("Name: worker\nVmRSS:\t123 kB\n"), 125952)
        with self.assertRaises(ValueError): sampler._cpu_time("not-time")

    def test_visible_quota_uses_strictest_ancestor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaf = root / "group" / "leaf"
            leaf.mkdir(parents=True)
            (root / "cpu.max").write_text("max 100000")
            (root / "group" / "cpu.max").write_text("50000 100000")
            (leaf / "cpu.max").write_text("200000 100000")
            self.assertEqual(sampler._quota_tree(root, leaf), (.5, "visible_limit"))
            (root / "group" / "cpu.max").write_text("max 100000")
            (leaf / "cpu.max").write_text("max 100000")
            self.assertEqual(sampler._quota_tree(root, leaf), (None, "visible_unlimited"))
            self.assertEqual(sampler._quota_tree(root, root / "missing"), (None, "unavailable"))

    def test_real_allocation_cpu_and_fd_growth_then_release(self):
        with owned_child() as child, sampler.Process(child.pid, "server") as process:
            initial = process.sample()
            self.assertEqual(initial["state"], "running")
            self.assertIsNone(initial["cpu_percent"])
            child.stdin.write("grow\n"); child.stdin.flush()
            self.assertEqual(child.stdout.readline().strip(), "done")
            grown = process.sample()
            self.assertGreater(grown["cpu_seconds"], initial["cpu_seconds"])
            self.assertGreater(grown["cpu_percent"], 0)
            self.assertGreater(grown["rss_bytes"], initial["rss_bytes"] + (4 << 20))
            self.assertEqual(grown["fd_count"], initial["fd_count"] + 16)
            child.stdin.write("shrink\n"); child.stdin.flush()
            self.assertEqual(child.stdout.readline().strip(), "done")
            released = process.sample()
            self.assertEqual(released["fd_count"], initial["fd_count"])
            self.assertEqual(released["start_token"], initial["start_token"])
            child.terminate(); child.wait(timeout=3)
            dead = process.sample()
            self.assertEqual(dead["state"], "exited")
            for field in ("cpu_seconds", "cpu_percent", "rss_bytes", "fd_count", "fd_limit_soft", "fd_limit_hard", "fd_limit_source"):
                self.assertNotIn(field, dead)
            self.assertEqual(process.sample()["state"], "exited")

    def test_cli_artifact_and_missing_pid_gate(self):
        script = Path(sampler.__file__)
        with owned_child() as server, owned_child() as loader:
            command = [sys.executable, str(script), "--server-pid", str(server.pid), "--loader-pid", str(loader.pid), "--interval", ".1", "--samples", "2"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = json.loads(result.stdout)
            self.assertTrue(artifact["valid"])
            self.assertEqual(len(artifact["samples"]), 2)
            self.assertGreater(artifact["collector"]["cpu_seconds"], 0)
            self.assertGreater(artifact["collector"]["collection_wall_seconds"], 0)
            for sample in artifact["samples"]:
                self.assertGreater(sample["wall_time_ns"], 0)
                self.assertEqual(set(sample["processes"]), {"server", "loader"})
                self.assertTrue(all(p["state"] == "running" for p in sample["processes"].values()))
            loader.terminate(); loader.wait(timeout=3)
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            artifact = json.loads(result.stdout)
            self.assertFalse(artifact["valid"])
            self.assertEqual(artifact["samples"][0]["processes"]["loader"]["state"], "exited")
            self.assertNotIn("rss_bytes", artifact["samples"][0]["processes"]["loader"])


if __name__ == "__main__":
    unittest.main()
