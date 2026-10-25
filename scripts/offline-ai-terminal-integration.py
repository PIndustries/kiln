#!/usr/bin/env python3
"""Real SSH AI acceptance using a disposable loopback Ollama-protocol fixture.

No model, credentials, provider traffic, production test switches or paid inference.
Requires pyte. Exercises production HTTP -> tools -> SSH -> terminal rendering.
"""
import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time

import pyte

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get("KILN_BIN_DIR", ROOT / ".build/debug"))


def freeport():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_lock = threading.Lock()
    request_count = 0
    last_messages = []
    last_model = ""

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        assert self.path == "/api/chat" and 0 < length <= 262144
        body = json.loads(self.rfile.read(length))
        messages = body["messages"]
        with Fixture.requests_lock:
            Fixture.request_count += 1
            Fixture.last_messages = messages
            Fixture.last_model = body["model"]
        prompt = next(item["content"] for item in reversed(messages) if item["role"] == "user")
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(content="", tools=None, done=False, thinking=""):
            value = {"message": {"role": "assistant", "content": content}, "done": done}
            if thinking:
                value["message"]["thinking"] = thinking
            if tools:
                value["message"]["tool_calls"] = [{"function": tools}]
            if done:
                value.update(done_reason="stop", prompt_eval_count=17, eval_count=5)
            self.wfile.write(json.dumps(value).encode() + b"\n")
            self.wfile.flush()

        try:
            if messages[-1]["role"] == "tool":
                emit("Fixture tool result received. ")
                time.sleep(0.25)
                emit("Review the local evidence and approval.", done=True)
            elif prompt == "fixture saved remember":
                for i in range(12):
                    emit(thinking=f"Visible investigation row {i:02d}\n")
                    time.sleep(0.05)
                emit("Saved checkpoint token MARBLE.", done=True)
            elif prompt == "fixture saved continue":
                emit("Saved context resumed.", done=True)
            elif prompt == "fixture saved after restart":
                emit("Saved after cold restart.", done=True)
            elif prompt == "fixture attributed follow-up":
                emit("Alternate source answer complete.", done=True)
            elif prompt.startswith("fixture context turn "):
                emit("Context turn " + prompt.rsplit(" ", 1)[1] + " completed.", done=True)
            elif "fixture restart" in prompt:
                emit(tools={"name": "request_operation", "arguments": {"module": "fixture/worker", "operation": "restart"}}, done=True)
            elif "fixture inspect" in prompt:
                emit(tools={"name": "list_modules", "arguments": {}}, done=True)
            elif "fixture slow" in prompt:
                for i in range(40):
                    emit(f"frame-{i:02d} ")
                    time.sleep(0.15)
                emit("complete", done=True)
            else:
                emit("Fixture follow-up completed.", done=True)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected cancellation/disconnect.
        finally:
            self.close_connection = True


with tempfile.TemporaryDirectory(prefix="kiln-offline-ai-") as directory:
    root = pathlib.Path(directory)
    state = root / "state"
    key = root / "admin"
    port, app_port = freeport(), freeport()
    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    fixture.daemon_threads = True
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    log = open(root / "runtime.log", "w+")
    runtime = subprocess.Popen([str(BIN / "kiln"), "up", "--state", str(state), "--authorized-keys", str(key) + ".pub", "--port", str(port)], stdout=log, stderr=log)
    clients = []
    try:
        deadline = time.monotonic() + 15
        while not (state / "ssh-host-ed25519.pub").exists():
            assert time.monotonic() < deadline, "SSH identity not created"
            time.sleep(0.05)
        known = root / "known"
        known.write_text(f"[127.0.0.1]:{port} " + (state / "ssh-host-ed25519.pub").read_text())
        base = ["ssh", "-F", "/dev/null", "-e", "none", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known}", "-i", str(key), "-p", str(port)]

        def command(text):
            result = subprocess.run(base + ["admin@127.0.0.1", text], capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, (text, result.stdout, result.stderr)
            return result.stdout

        while True:
            result = subprocess.run(base + ["admin@127.0.0.1", "status"], capture_output=True, timeout=3)
            if result.returncode == 0:
                break
            assert time.monotonic() < deadline
            time.sleep(0.05)
        command(f"ai profile add offline ollama http://127.0.0.1:{fixture.server_port} fixture-model")
        command("ai profile use offline --new-context")
        command(f"ai profile add alternate ollama http://127.0.0.1:{fixture.server_port} fixture-other")
        manifest = root / "worker.json"
        manifest.write_text(json.dumps(dict(application="fixture", name="worker", version="1", executable=str(BIN / "kiln-example-backend"), arguments=["--port", str(app_port)], healthURL=f"http://127.0.0.1:{app_port}/health")))
        command(f"app install {manifest}")
        command("app start fixture/worker")

        def pid():
            return int(next(line for line in command("app list").splitlines() if "fixture" in line and "worker" in line).split()[-1])

        def connect():
            global master, screen, stream, client, raw
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 120, 0, 0))
            client = subprocess.Popen(base + ["-tt", "admin@127.0.0.1"], stdin=slave, stdout=slave, stderr=slave, env={**os.environ, "TERM": "xterm-256color"})
            os.close(slave)
            clients.append((client, master))
            screen = pyte.Screen(120, 38)
            stream = pyte.ByteStream(screen)
            raw = bytearray()
            expect("7 AI Chat")
            expect("Selected AI: Ollama | Ollama daemon")
            send(b"7")
            expect("KILN AI CHAT")
            expect("selected: Ollama")
            expect("Ollama daemon / ollama / offline")

        def frame():
            return "\n".join(screen.display)

        def pump(seconds=0.1):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                ready, _, _ = select.select([master], [], [], max(0, end - time.monotonic()))
                if ready:
                    data = os.read(master, 65536)
                    assert data, "SSH client disconnected unexpectedly"
                    raw.extend(data)
                    stream.feed(data)

        def expect(text, seconds=15):
            end = time.monotonic() + seconds
            while text not in frame():
                pump()
                assert time.monotonic() < end, (text, frame())

        def send(data):
            os.write(master, data)
            pump()

        def click(text):
            # SSH may deliver the heading before the button rows in the same
            # frame. Wait for the actual target instead of treating a partial
            # terminal paint as a complete review screen.
            expect(text)
            for y, line in enumerate(screen.display):
                x = line.find(text)
                if x >= 0:
                    send(f"\x1b[<0;{x + 2};{y + 1}M\x1b[<0;{x + 2};{y + 1}m".encode())
                    return
            raise AssertionError(("Missing click target", text, frame()))

        connect()
        expect("ollama / offline")
        with Fixture.requests_lock:
            count = Fixture.request_count
        send(b"/help\r")
        expect("Help makes no provider request.")
        expect("[ready]")
        send(b"/provider\r")
        expect("Provider: ollama / profile offline")
        expect("[ready]")
        send(b"/providers\r")
        expect("Switch: /provider NAME --new-context")
        expect("[ready]")
        selected_before_check = (state / "ai.json").read_bytes()
        send(b"/check\r")
        expect("Local setup checks passed.")
        expect("No credentials were renewed")
        expect("[ready]")
        assert (state / "ai.json").read_bytes() == selected_before_check
        for shortcut in [b"/task", b"/watch", b"/cancel", b"/recover", b"/approve", b"/deny"]:
            send(shortcut + b"\r")
            expect("Usage: " + shortcut.decode())
        with Fixture.requests_lock:
            assert Fixture.request_count == count, "Local chat controls called the provider"
        send(b"/context\r")
        expect("Completed turns: 0")
        expect("[ready]")
        with Fixture.requests_lock:
            assert Fixture.request_count == count, "Context command called the provider"
        send(b"unsent AI draft")
        send(b"`")
        expect("COMMAND DRAWER")
        send(b"status\r")
        expect("runtime running")
        send(b"`")
        send(b"7")
        expect("KILN AI CHAT")
        send(b"\x1b")
        expect("7 AI Chat")
        send(b"`")
        expect("COMMAND DRAWER")
        send(b"status\r")
        expect("runtime running")
        send(b"`")
        send(b"7")
        expect("KILN AI CHAT")
        print("PASS offline SSH: backtick opens commands from AI chat and after Escape; status executes as a CLI command", flush=True)
        send(b"fixture slow\r")
        expect("frame-02")
        selection_start = len(raw)
        send(b"\x13")
        expect("SELECT TEXT")
        # Mouse capture is disabled after the selection frame is fully sent.
        # Freezing a partially received frame would mistake its remaining bytes
        # for a repaint during selection.
        end = time.monotonic() + 15
        while b"\x1b[?1000l\x1b[?1002l\x1b[?1006l" not in raw[selection_start:]:
            pump()
            assert time.monotonic() < end, "Selection frame did not finish"
        frozen = list(screen.display)
        pump(0.7)
        assert screen.display == frozen, "Selection repainted during incoming content"
        send(b"\x13")
        expect("frame-08")
        send(b"\x03")
        expect("[ready]")
        send(b"fixture follow-up\r")
        expect("Fixture follow-up completed.")
        expect("[ready]")
        print("PASS offline SSH: incremental frames, frozen selection during streaming, cancellation and successful follow-up", flush=True)

        before = pid()
        send(b"fixture restart\r")
        expect("APPROVAL / restart")
        expect("[ready]")
        click("APPROVAL / restart")
        expect("REVIEW OPERATION")
        click("Deny")
        expect("Proposal declined")
        expect("0 approvals")
        assert pid() == before
        send(b"fixture restart again\r")
        expect("APPROVAL / restart")
        expect("[ready]")
        send(b"\t\r")
        expect("REVIEW OPERATION")
        send(b"\r")
        expect("0 approvals")
        expect("[ready]")
        assert pid() != before
        receipts = [json.loads(path.read_text()) for path in (state / "operations").glob("*.json")]
        assert len(receipts) == 1 and receipts[0]["operation"] == "restart" and receipts[0]["state"] == "succeeded", receipts
        assert receipts[0]["module"] == "fixture/worker"
        print("PASS offline SSH: mouse denial leaves PID unchanged; keyboard approval restarts once and consumes proposal", flush=True)

        # A foreground proposal must not become actionable in a new SSH session.
        send(b"fixture restart pending\r")
        expect("APPROVAL / restart")
        expect("[ready]")
        send(b"fixture slow\r")
        expect("frame-02")
        client.kill()
        client.wait(timeout=5)
        connect()
        expect("0 approvals / 0 tasks")
        assert "frame-02" not in frame()
        assert len(list((state / "operations").glob("*.json"))) == 1, "Reconnect repeated an operation"
        send(b"fixture inspect\r")
        expect("Fixture tool result received.")
        expect("[ready]")
        metrics = command("ai metrics")
        assert "ollama: usage supplied for" in metrics and "total=unavailable" in metrics, metrics
        print("PASS offline SSH: disconnect during foreground stream; reconnect has no stale proposal/history; fresh read tool and usage report work", flush=True)
        # Query metadata and cross the history limit in one real SSH connection.
        # Distinct replies prevent an old answer from satisfying a later wait.
        send(b"/reset\r")
        expect("AI conversation and pending proposals cleared")
        expect("[ready]")
        for index in range(22):
            send(f"fixture context turn {index}\r".encode())
            expect(f"Context turn {index} completed.")
            expect("[ready]")
        expect("Context trimmed:")
        with Fixture.requests_lock:
            users = [m["content"] for m in Fixture.last_messages if m["role"] == "user"]
            count = Fixture.request_count
        assert "fixture context turn 0" not in users and "fixture context turn 1" in users
        send(b"/context\r")
        expect("Completed turns: 21")
        expect("42 messages / 40 limit")
        expect("oldest complete turns will be omitted")
        expect("[ready]")
        with Fixture.requests_lock:
            assert Fixture.request_count == count, "Context command called the provider"
        print("PASS offline SSH: context metadata makes no provider request; 22 turns retain recent context and show trimming", flush=True)
        # Switch the selected profile while a slow request keeps its original
        # immutable configuration. The stream's actual source must stay visible.
        send(b"fixture slow\r")
        expect("frame-02")
        command("ai profile use alternate --new-context")
        expect("Model: fixture-other")
        expect("via Ollama / offline")
        with Fixture.requests_lock:
            assert Fixture.last_model == "fixture-model", "In-flight wire model changed"
        expect("frame-39")
        expect("[ready]")
        expect("KILN / Ollama / offline / fixture-model")
        send(b"fixture attributed follow-up\r")
        expect("Alternate source answer complete.")
        expect("[ready]")
        expect("KILN / Ollama / alternate / fixture-other")
        expect("KILN / Ollama / offline / fixture-model")
        with Fixture.requests_lock:
            assert Fixture.last_model == "fixture-other"
        print("PASS offline SSH: request source stays pinned during profile switch; completed answers retain their actual models", flush=True)
        with Fixture.requests_lock:
            count = Fixture.request_count
        send(b"/provider offline\r")
        expect("Use /provider NAME --new-context")
        expect("Model: fixture-other")
        send(b"/provider offline --new-context\r")
        expect("Selected offline.")
        expect("[ready]")
        expect("Model: fixture-model")
        send(b"/context\r")
        expect("Completed turns: 0")
        expect("[ready]")
        with Fixture.requests_lock:
            assert Fixture.request_count == count, "Profile selection called the provider"
        send(b"fixture context turn 999\r")
        expect("Context turn 999 completed.")
        expect("[ready]")
        with Fixture.requests_lock:
            assert Fixture.last_model == "fixture-model"
            assert not any(m.get("content") == "fixture attributed follow-up" for m in Fixture.last_messages)
        print("PASS offline SSH: provider inspection and explicit chat selection make no model request; next turn uses a fresh context and selected model", flush=True)
        send(b"/conversation new durable-acceptance\r")
        expect("Saved: durable-acceptance")
        expect("[ready]")
        send(b"\x14")  # Expand retained thinking for this explicit transcript test.
        send(b"fixture saved remember\r")
        expect("Visible investigation row 00")
        expect("Visible investigation row 11")
        expect("Saved checkpoint token MARBLE.")
        expect("[ready]")
        saved = json.loads(command("ai conversation show durable-acceptance"))
        cursor = saved["latestCursor"]
        assert saved["schemaVersion"] == 1 and not saved["gap"]
        thinking = "".join(e["text"] for e in saved["events"] if e["kind"] == "reasoning")
        assert "Visible investigation row 00" in thinking and "Visible investigation row 11" in thinking
        assert (state / "ai-conversations/index.json").stat().st_mode & 0o777 == 0o600
        client.kill(); client.wait(timeout=5)
        with Fixture.requests_lock:
            count = Fixture.request_count
        connect()
        assert "Saved: durable-acceptance" not in frame()
        send(b"\x14")
        send(b"/conversation use durable-acceptance\r")
        expect("Saved: durable-acceptance")
        expect("Visible investigation row 00")
        expect("Saved checkpoint token MARBLE.")
        expect("[ready]")
        with Fixture.requests_lock:
            assert Fixture.request_count == count, "Restoring transcript called provider"
        send(b"fixture saved continue\r")
        expect("Saved context resumed."); expect("[ready]")
        with Fixture.requests_lock:
            assert any(m.get("content") == "fixture saved remember" for m in Fixture.last_messages)
            assert not any("Visible investigation row" in m.get("content", "") or m.get("content") == "fixture context turn 999" for m in Fixture.last_messages)
        send(b"fixture restart saved pending\r")
        expect("APPROVAL / restart"); expect("[ready]")
        saved = json.loads(command("ai conversation show durable-acceptance"))
        import re
        proposal = next(re.search(r"Approve: /approve ([a-zA-Z0-9-]+)", e["text"]).group(1) for e in reversed(saved["events"]) if "Approve: /approve " in e["text"])
        client.kill(); client.wait(timeout=5)
        runtime.terminate(); runtime.wait(timeout=15)
        stopped = subprocess.run([str(BIN / "kiln"), "session-service-stop", "--state", str(state)], capture_output=True, timeout=8)
        assert stopped.returncode == 0 or not (state / "session-service.pid").exists()
        runtime = subprocess.Popen([str(BIN / "kiln"), "up", "--state", str(state), "--authorized-keys", str(key) + ".pub", "--port", str(port)], stdout=log, stderr=log)
        deadline = time.monotonic() + 15
        while subprocess.run(base + ["admin@127.0.0.1", "status"], capture_output=True, timeout=3).returncode:
            assert time.monotonic() < deadline, "Cold runtime restart failed"
            time.sleep(0.1)
        connect()
        send(b"/conversation use durable-acceptance\r")
        expect("Saved: durable-acceptance"); expect("[ready]")
        expect("0 approvals / 0 tasks")
        before = pid()
        send(f"/approve {proposal}\r".encode())
        expect("Unknown proposal"); expect("[ready]")
        assert pid() == before and len(list((state / "operations").glob("*.json"))) == 1
        send(b"fixture saved after restart\r")
        expect("Saved after cold restart."); expect("[ready]")
        with Fixture.requests_lock:
            assert any(m.get("content") == "fixture saved continue" for m in Fixture.last_messages)
        events = json.loads(command(f"ai conversation show durable-acceptance {cursor}"))
        assert not events["gap"] and all(e["cursor"] > cursor for e in events["events"])
        command("ai conversation retention durable-acceptance 1")
        command("ai conversation delete durable-acceptance")
        deadline = time.monotonic() + 5
        # Header and body rows can arrive in separate SSH packets. Wait for
        # both changes rather than asserting against a partially painted frame.
        while "Saved: durable-acceptance" in frame() or "Saved after cold restart." in frame():
            pump(); assert time.monotonic() < deadline, "Deleted conversation still selected or visible"
        assert "No saved conversations" in command("ai conversation list")
        print("PASS offline SSH: full visible thinking retained and restored; named context survives reconnect/cold restart; approvals never revive; cursor reads and connected deletion verified", flush=True)
        print("KILN_OFFLINE_AI_TERMINAL_COMPLETE", flush=True)
    except Exception:
        log.flush()
        print((root / "runtime.log").read_text(), flush=True)
        raise
    finally:
        for process, descriptor in clients:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(descriptor)
        if runtime.poll() is None:
            runtime.terminate()
        runtime.wait(timeout=15)
        subprocess.run([str(BIN / "kiln"), "session-service-stop", "--state", str(state)], capture_output=True, timeout=8)
        fixture.shutdown()
        fixture.server_close()
        log.close()
