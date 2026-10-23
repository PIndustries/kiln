#!/usr/bin/env python3
"""Real SSH bundle install, assets/libraries, deploy, rejection, restore and rollback.

Compiles disposable C fixtures with the host compiler; no model, credentials,
network downloads or existing user state. Consumers do not need a compiler.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get("KILN_BIN_DIR", ROOT / ".build/debug"))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--legacy-bin", type=pathlib.Path, help="Optional previous runtime: must reject bundle state without changing it")
args = parser.parse_args()
target = {("Darwin", "arm64"): "macos-arm64", ("Linux", "x86_64"): "linux-x86_64"}[(platform.system(), platform.machine())]


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix="kiln-bundle-") as directory:
    root = pathlib.Path(directory)
    state, key = root / "state with spaces", root / "admin"
    ssh_port, ingress = port(), port()
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    log = (root / "runtime.log").open("w+")
    runtime = None
    known = root / "known"
    base = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known}", "-i", str(key), "-p", str(ssh_port), "admin@127.0.0.1"]

    def start():
        global runtime
        runtime = subprocess.Popen([str(BIN / "kiln"), "up", "--state", str(state), "--authorized-keys", str(key) + ".pub", "--port", str(ssh_port)], stdout=log, stderr=log)
        deadline = time.monotonic() + 15
        while not (state / "ssh-host-ed25519.pub").exists():
            assert runtime.poll() is None and time.monotonic() < deadline
            time.sleep(.05)
        known.write_text(f"[127.0.0.1]:{ssh_port} " + (state / "ssh-host-ed25519.pub").read_text())
        while True:
            result = subprocess.run(base + ["status"], capture_output=True, timeout=3)
            if not result.returncode:
                return
            assert runtime.poll() is None and time.monotonic() < deadline
            time.sleep(.05)

    def command(text, success=True):
        result = subprocess.run(base + [text], capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == success, (text, result.stdout, result.stderr)
        return result.stdout

    def stop():
        global runtime
        if runtime and runtime.poll() is None:
            runtime.terminate(); runtime.wait(timeout=15)
        runtime = None
        pid_file = state / "session-service.pid"
        pid = pid_file.read_text().strip() if pid_file.exists() else None
        subprocess.run([str(BIN / "kiln"), "session-service-stop", "--state", str(state)], capture_output=True, timeout=10)
        if pid:
            end = time.monotonic() + 10
            while subprocess.run(["ps", "-p", pid], stdout=subprocess.DEVNULL).returncode == 0:
                assert time.monotonic() < end, "Session service did not stop"
                time.sleep(.05)

    def bundle(version, value, fail=False):
        payload = root / ("payload " + version)
        for part in ["bin", "lib", "assets"]:
            (payload / part).mkdir(parents=True, exist_ok=True)
        library = root / ("library-" + version + ".c")
        library.write_text(f"int bundle_value(void) {{ return {value}; }}\n")
        mac = platform.system() == "Darwin"
        suffix = ".dylib" if mac else ".so"
        options = ["-dynamiclib", "-Wl,-install_name,@rpath/libkilnbundle.dylib"] if mac else ["-shared", "-fPIC"]
        subprocess.run(["cc", *options, str(library), "-o", str(payload / "lib" / ("libkilnbundle" + suffix))], check=True)
        rpath = "@executable_path/../lib" if mac else "$ORIGIN/../lib"
        subprocess.run(["cc", str(ROOT / "Tests/Fixtures/bundle-worker.c"), "-L" + str(payload / "lib"), "-lkilnbundle", "-Wl,-rpath," + rpath, "-o", str(payload / "bin/worker")], check=True)
        (payload / "assets/message.txt").write_text("bundle-" + version)
        worker_port = port()
        manifest = dict(application="portable", name="api", version=version, executable="bin/worker", arguments=["fail"] if fail else [], ingressPort=ingress, healthURL=f"http://127.0.0.1:{worker_port}/health")
        source = root / ("manifest-" + version + ".json")
        source.write_text(json.dumps(manifest))
        output = root / ("bundle release " + version)
        subprocess.run(["python3", str(ROOT / "scripts/application-bundle.py"), "--manifest", str(source), "--payload", str(payload), "--output", str(output), "--platform", target], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(payload)
        return output

    def response(asset, value):
        # Do not inherit proxy settings for this literal-loopback fixture.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://127.0.0.1:{ingress}/", timeout=5) as reply:
            result = json.load(reply)
        assert result["asset"] == asset and result["library"] == value, result
        return result

    try:
        one, two = bundle("1", 101), bundle("2", 202)
        start()
        command(f'app install "{one}"')
        shutil.rmtree(one)
        command("app start portable/api")
        first = response("bundle-1", 101)
        command(f'app deploy "{two}"')
        shutil.rmtree(two)
        second = response("bundle-2", 202)
        assert second["starts"] > first["starts"]
        assert "Previous: 1" in command("app releases portable/api")
        print("PASS bundle install/deploy after source removal: assets and relative shared library, persistent data", flush=True)

        bad = bundle("3", 303)
        (bad / "assets/message.txt").chmod(0o600)
        (bad / "assets/message.txt").write_text("corrupt")
        command(f'app deploy "{bad}"', success=False)
        response("bundle-2", 202)
        assert not (state / "releases/portable/api/3").exists()
        unready = bundle("4", 404, fail=True)
        command(f'app deploy "{unready}"', success=False)
        response("bundle-2", 202)
        assert "Previous: 1" in command("app releases portable/api")
        assert not (state / "releases/portable/api/4").exists()
        print("PASS checksum/readiness rejection preserves active and previous bundle releases", flush=True)

        stop()
        if args.legacy_bin:
            index = state / "applications.json"
            before = hashlib.sha256(index.read_bytes()).digest()
            rejected = subprocess.run([str(args.legacy_bin), "up", "--state", str(state), "--no-ssh"], capture_output=True, text=True, timeout=10)
            assert rejected.returncode != 0 and "Unsupported application state format" in rejected.stdout + rejected.stderr
            assert hashlib.sha256(index.read_bytes()).digest() == before
            print("PASS prior runtime rejects bundle state without modifying it", flush=True)
        start()
        restored = response("bundle-2", 202)
        assert restored["starts"] > second["starts"]
        command("app rollback portable/api")
        rolled_back = response("bundle-1", 101)
        assert rolled_back["starts"] > restored["starts"]
        assert "Previous: 2" in command("app releases portable/api")
        assert json.loads((state / "applications.json").read_text())["formatVersion"] == 3
        print("PASS cold restore and rollback retain complete bundle payloads and persistent data", flush=True)
        previous = state / "releases/portable/api/2/bundle.json"
        altered = json.loads(previous.read_text()); altered["module"]["version"] = "tampered"
        previous.write_text(json.dumps(altered))
        command("app rollback portable/api", success=False)
        response("bundle-1", 101)
        assert int((state / "data/portable/api/starts").read_text()) == rolled_back["starts"]
        print("PASS altered installed manifest cannot execute a rollback worker or replace the active release", flush=True)
        print("KILN_BUNDLE_INTEGRATION_COMPLETE", flush=True)
    except BaseException:
        log.flush(); log.seek(0)
        print(log.read()[-8000:], file=sys.stderr)
        raise
    finally:
        stop()
        log.close()
