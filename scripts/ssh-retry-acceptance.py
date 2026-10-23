#!/usr/bin/env python3
"""Opt-in real SSH sidebar acceptance with a test-process Erebine HTTP fixture.

Requires pyte. No credentials or provider calls.
"""
import argparse
import fcntl
import os
import pathlib
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import time
import pyte

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-system", choices=["native", "swiftbuild"])
args = parser.parse_args()
command = ["swift", "test", "--force-resolved-versions", "--jobs", "4", "--filter", "sshRetryAcceptance"]
if args.build_system:
    command += ["--build-system", args.build_system]
with tempfile.TemporaryDirectory(prefix="kiln-ssh-retry-") as directory:
    root = pathlib.Path(directory)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "admin")], check=True)
    with (root / "test.log").open("w+") as log:
        test = subprocess.Popen(command, cwd=ROOT,
            env={**os.environ, "KILN_SSH_RETRY_STATE": str(root), "KILN_SSH_RETRY_PORT": str(port)}, stdout=log, stderr=log)
        client = None
        master = None
        try:
            deadline = time.monotonic() + 180
            while not (root / "ready").exists():
                if test.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError(log.read())
                time.sleep(.1)
            known = root / "known"
            known.write_text(f"[127.0.0.1]:{port} " + (root / "state/ssh-host-ed25519.pub").read_text())
            base = ["ssh", "-F", "/dev/null", "-e", "none", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known}", "-i", str(root / "admin"), "-p", str(port)]
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 120, 0, 0))
            client = subprocess.Popen(base + ["-tt", "admin@127.0.0.1"], stdin=slave, stdout=slave, stderr=slave, env={**os.environ, "TERM": "xterm-256color"})
            os.close(slave)
            screen = pyte.Screen(120, 38)
            stream = pyte.ByteStream(screen)

            def frame():
                return "\n".join(screen.display)

            def expect(text, timeout=15):
                end = time.monotonic() + timeout
                while text not in frame():
                    assert time.monotonic() < end, (text, frame())
                    if select.select([master], [], [], .1)[0]:
                        data = os.read(master, 65536)
                        assert data, "SSH disconnected"
                        stream.feed(data)

            expect("7 AI Chat")
            os.write(master, b"7")
            expect("KILN AI CHAT")
            os.write(master, b"retry sidebar\r")
            expect("Provider busy; retry 1/2 in 5s")
            # A second SSH channel creates a real durable task while foreground
            # inference waits. The ordinary sidebar poll must observe completion.
            result = subprocess.run(base + ["admin@127.0.0.1", "ai task new inspect fixture"], capture_output=True, text=True, timeout=3)
            assert result.returncode == 0 and "Task created:" in result.stdout, result.stdout + result.stderr
            expect("TASK / completed", timeout=4)
            assert "Provider busy; retry" in frame(), frame()
            assert "Retry fixture recovered." not in frame(), frame()
            expect("Retry fixture recovered.")
            expect("[ready]")
            assert "TASK / completed" in frame(), frame()
            (root / "passed").touch()
            print("PASS real SSH: task sidebar refreshed during Erebine retry countdown and persisted after recovery", flush=True)
        finally:
            if client:
                client.kill()
                client.wait(timeout=5)
            if master is not None:
                os.close(master)
            (root / "done").touch()
            try:
                code = test.wait(timeout=15)
            except subprocess.TimeoutExpired:
                test.kill()
                test.wait()
                raise
        if code:
            log.seek(0)
            raise AssertionError(log.read())
