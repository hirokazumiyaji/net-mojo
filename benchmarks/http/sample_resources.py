"""Sample public process resources on Linux and macOS."""

import argparse
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import platform
import resource
import select
import subprocess
import sys
import time


def _cpu_time(text):
    days, clock = text.split("-", 1) if "-" in text else ("0", text)
    fields = [float(value) for value in clock.split(":")]
    if len(fields) not in (2, 3):
        raise ValueError("unexpected cumulative CPU time")
    seconds = 0
    for value in fields:
        seconds = seconds * 60 + value
    return int(days) * 86400 + seconds


def _numeric_fds(text):
    return len({line[1:] for line in text.splitlines() if line.startswith("f") and line[1:].isdigit()})


def _linux_stat(text):
    fields = text.rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12]), fields[19]


def _linux_rss(text):
    for line in text.splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    raise ValueError("VmRSS is unavailable")


def _quota_tree(root, leaf):
    if not leaf.is_relative_to(root) or not leaf.is_dir():
        return None, "unavailable"
    quotas, seen = [], False
    try:
        current = leaf
        while True:
            try:
                values = (current / "cpu.max").read_text().split()
            except FileNotFoundError:
                pass
            else:
                seen = True
                if values[0] != "max":
                    quotas.append(int(values[0]) / int(values[1]))
            if current == root:
                break
            current = current.parent
    except (OSError, ValueError):
        return None, "unavailable"
    return (min(quotas), "visible_limit") if quotas else (None, "visible_unlimited" if seen else "unavailable")


def _linux_snapshot(pid):
    directory = Path("/proc") / str(pid)
    ticks, start = _linux_stat((directory / "stat").read_text())
    captured = time.monotonic_ns()
    quota, quota_state = None, "unavailable"
    for line in (directory / "cgroup").read_text().splitlines():
        if line.startswith("0::"):
            root = Path("/sys/fs/cgroup")
            membership = Path(line[3:]).relative_to("/")
            if ".." not in membership.parts:
                quota, quota_state = _quota_tree(root, root / membership)
            break
    with os.scandir(directory / "fd") as entries:
        fds = sum(entry.name.isdigit() for entry in entries)
    hz = os.sysconf("SC_CLK_TCK")
    return {"start_token": start, "cpu_seconds": ticks / hz, "cpu_monotonic_ns": captured,
            "cpu_time_resolution_seconds": 1 / hz, "rss_bytes": _linux_rss((directory / "status").read_text()),
            "fd_count": fds, "cpu_affinity": sorted(os.sched_getaffinity(pid)),
            "cpu_quota_cores": quota, "cpu_quota_state": quota_state}


def _mac_snapshot(pid):
    ps = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "time=", "-o", "rss="],
                        capture_output=True, text=True, check=True, timeout=5).stdout.split()
    captured = time.monotonic_ns()
    fds = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Ff"],
                         capture_output=True, text=True, check=True, timeout=5).stdout
    return {"start_token": " ".join(ps[:-2]), "cpu_seconds": _cpu_time(ps[-2]),
            "cpu_monotonic_ns": captured, "cpu_time_resolution_seconds": .01,
            "rss_bytes": int(ps[-1]) * 1024, "fd_count": _numeric_fds(fds),
            "cpu_affinity": None, "cpu_quota_cores": None, "cpu_quota_state": "not_exposed"}


class _ProcessWatch:
    def __init__(self, pid):
        if sys.platform == "linux":
            self.fd = os.pidfd_open(pid)
            self.poll = select.poll()
            self.poll.register(self.fd, select.POLLIN)
        elif sys.platform == "darwin":
            self.queue = select.kqueue()
            try:
                event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                      flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
                self.queue.control([event], 0, 0)
            except OSError:
                self.queue.close()
                raise
        else:
            raise ValueError("only Linux and macOS are supported")

    def exited(self):
        if sys.platform == "linux":
            return bool(self.poll.poll(0))
        return bool(self.queue.control(None, 1, 0))

    def close(self):
        if sys.platform == "linux":
            os.close(self.fd)
        else:
            self.queue.close()


class Process:
    def __init__(self, pid, role):
        self.pid, self.role = pid, role
        self.state, self.start_token, self.previous = "running", None, None
        self.watch, self.error = None, None
        try:
            self.watch = _ProcessWatch(pid)
        except ProcessLookupError:
            self.state = "exited"
        except (OSError, ValueError) as error:
            self.state, self.error = "error", str(error)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        if self.watch is not None:
            self.watch.close()

    def sample(self):
        record = {"pid": self.pid, "role": self.role, "state": self.state, "start_token": self.start_token}
        if self.state == "running":
            try:
                if self.watch.exited():
                    self.state = "exited"
                else:
                    data = _linux_snapshot(self.pid) if sys.platform == "linux" else _mac_snapshot(self.pid)
                    if self.watch.exited():
                        self.state = "exited"
                    elif self.start_token is not None and self.start_token != data["start_token"]:
                        self.state = "reused"
                    else:
                        self.start_token = data["start_token"]
                        data["cpu_percent"] = None
                        if self.previous is not None:
                            elapsed = (data["cpu_monotonic_ns"] - self.previous["cpu_monotonic_ns"]) / 1e9
                            data["cpu_percent"] = 100 * (data["cpu_seconds"] - self.previous["cpu_seconds"]) / elapsed
                        self.previous = data
                        record.update(data)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                if self.watch.exited():
                    self.state = "exited"
                else:
                    self.state, self.error = "error", str(error)
        record["state"] = self.state
        if self.error is not None:
            record["error"] = self.error
        return record


def _collector_cpu():
    return sum(usage.ru_utime + usage.ru_stime for usage in
               (resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)))


def collect(pids, interval, samples):
    start, cpu_start = time.monotonic_ns(), _collector_cpu()
    rows = []
    with ExitStack() as stack:
        processes = {role: stack.enter_context(Process(pid, role)) for role, pid in pids.items()}
        for index in range(samples):
            planned = start + int(index * interval * 1e9)
            time.sleep(max(0, (planned - time.monotonic_ns()) / 1e9))
            began = time.monotonic_ns()
            row = {"wall_time_ns": time.time_ns(), "monotonic_ns": began,
                   "schedule_lag_seconds": (began - planned) / 1e9,
                   "processes": {role: process.sample() for role, process in processes.items()}}
            row["collection_wall_seconds"] = (time.monotonic_ns() - began) / 1e9
            rows.append(row)
    elapsed = (time.monotonic_ns() - start) / 1e9
    cpu = _collector_cpu() - cpu_start
    return {"os": platform.system(), "release": platform.release(), "machine": platform.machine(),
            "host_logical_cpus": os.cpu_count(), "interval_seconds": interval, "samples_requested": samples,
            "valid": all(p["state"] == "running" for row in rows for p in row["processes"].values()),
            "collector": {"cpu_seconds": cpu, "elapsed_seconds": elapsed, "cpu_percent": 100 * cpu / elapsed,
                          "collection_wall_seconds": sum(row["collection_wall_seconds"] for row in rows)},
            "samples": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-pid", type=int, required=True)
    parser.add_argument("--loader-pid", type=int, required=True)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()
    if min(args.server_pid, args.loader_pid, args.samples) <= 0 or not math.isfinite(args.interval) or args.interval <= 0:
        parser.error("PIDs, samples and finite interval must be positive")
    result = collect({"server": args.server_pid, "loader": args.loader_pid}, args.interval, args.samples)
    print(json.dumps(result, allow_nan=False))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
