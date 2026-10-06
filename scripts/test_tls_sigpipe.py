"""Exercise the actual C shim against a real TLS peer's TCP reset."""

import argparse
import os
import selectors
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time


def read_line(process, timeout):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise TimeoutError("TLS child did not produce its next phase")
        line = process.stdout.readline()
    if not line:
        raise RuntimeError("TLS child exited before its next phase")
    print(line, end="", flush=True)
    return line.rstrip("\n")


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)
    if group_exists(process.pid):
        raise RuntimeError("Owned TLS child process group remains")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("child")
    parser.add_argument("certificate")
    parser.add_argument("private_key")
    args = parser.parse_args()
    parent_policy = signal.getsignal(signal.SIGPIPE)
    command = [args.child, args.certificate, args.private_key]
    started = time.monotonic()
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, start_new_session=True,
    )
    print(f"OWNED pid={process.pid} pgid={process.pid}", flush=True)
    output = ""
    error = ""
    try:
        ready = read_line(process, 10)
        fields = dict(field.split("=", 1) for field in ready.split()[1:])
        assert ready.startswith("READY ") and int(fields["pid"]) == process.pid
        context = ssl.create_default_context(cafile=args.certificate)
        context.set_alpn_protocols(["h2"])
        with socket.create_connection(("127.0.0.1", int(fields["port"])), 5) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as peer:
                assert peer.selected_alpn_protocol() == "h2"
                assert read_line(process, 5) == (
                    "HANDSHAKE policy=default-unblocked context-owner=dropped"
                )
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
        output, error = process.communicate(timeout=15)
        print(output, end="", flush=True)
        print(error, end="", file=sys.stderr, flush=True)
        print(f"CHILD_EXIT code={process.returncode} "
              f"elapsed={time.monotonic() - started:.6f}", flush=True)
        assert "PEER_RESET recv=-1 errno=104\n" in output
        assert process.returncode == 0, (
            f"TLS write terminated child: {process.returncode}; "
            "expected an ordinary NET_TLS_ERROR"
        )
        assert "TLS_WRITE result=-1 " in output
        assert "PASS policy=unchanged socket-owner=preserved\n" in output
    finally:
        stop(process)
        if process.stdout is not None and not process.stdout.closed:
            remainder, remaining_error = process.communicate(timeout=2)
            print(remainder, end="", flush=True)
            print(remaining_error, end="", file=sys.stderr, flush=True)
        assert signal.getsignal(signal.SIGPIPE) == parent_policy
        print(f"OWNED_ABSENT pgid={process.pid}", flush=True)


if __name__ == "__main__":
    main()
