#!/usr/bin/env python3
"""Rehearse previous package -> candidate -> previous on disposable persistent state.
No tag/release publication and no writes to a running user node.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# Public, tested package-era baseline. Never resolve a moving branch for recovery.
BASELINE_SHA = '360e36e01735c2efab17da73b7e6e50486ada073'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def wait(fn, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, AssertionError, subprocess.SubprocessError):
            pass
        time.sleep(.1)
    raise AssertionError('Fixture readiness or restoration deadline exceeded')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(package):
    info = json.loads((package / 'build-info.json').read_text())
    for entry in info['files']:
        assert digest(package / entry['path']) == entry['sha256'], entry['path']
    assert run(str(package / 'bin/kiln'), '--version').stdout.strip() == info['version']
    return info


def free_ports(count):
    sockets = [socket.socket() for _ in range(count)]
    try:
        for item in sockets:
            item.bind(('127.0.0.1', 0))
        return [item.getsockname()[1] for item in sockets]
    finally:
        for item in sockets:
            item.close()


def echo_websocket(port):
    def receive(client, size):
        value = b''
        while len(value) < size:
            part = client.recv(size - len(value))
            assert part, 'WebSocket closed'
            value += part
        return value
    with socket.create_connection(('127.0.0.1', port), timeout=2) as client:
        key = base64.b64encode(os.urandom(16)).decode()
        client.sendall((f'GET /ws HTTP/1.1\r\nHost: localhost:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        headers = b''
        while not headers.endswith(b'\r\n\r\n'):
            assert len(headers) < 8192
            headers += receive(client, 1)
        assert b'101 Switching Protocols' in headers
        payload = b'package-transition'; mask = os.urandom(4)
        client.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(x ^ mask[i % 4] for i, x in enumerate(payload)))
        assert receive(client, 2) == bytes([0x81, len(payload)])
        assert receive(client, len(payload)) == payload
        return True


def rehearse(previous, candidate, temporary):
    before, after = verify(previous), verify(candidate)
    assert before['sourceRevision'] == BASELINE_SHA
    assert before['version'] == '26.10.09.1'
    assert before['version'] != after['version'], 'Upgrade must exercise distinct release versions'
    assert before['platform'] == after['platform']
    packages = [previous, candidate]
    package_hashes = {str(p / 'bin' / n): digest(p / 'bin' / n) for p in packages for n in ['kiln', 'kiln-example-backend']}
    state = temporary / 'state'; key = temporary / 'admin'; known = temporary / 'known'
    vault_key = temporary / 'separate-key' / 'master'
    vault_key.parent.mkdir(mode=0o700)
    ssh_port, rest_port, ws_port, stopped_port, denied_port = free_ports(5)
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key))
    binary = previous / 'bin/kiln'; process = None
    log = (temporary / 'runtime.log').open('w+')
    def command(text, check=True):
        result = subprocess.run(['ssh', '-n', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-o', 'ConnectTimeout=2', '-i', str(key), '-p', str(ssh_port), 'admin@127.0.0.1', text], capture_output=True, text=True, timeout=20)
        if check:
            assert result.returncode == 0, f'Fixture command failed: {text}'
        return result
    def launch(package):
        nonlocal process, binary
        binary = package / 'bin/kiln'
        process = subprocess.Popen([str(binary), 'up', '--state', str(state), '--authorized-keys', str(key) + '.pub', '--port', str(ssh_port)], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        host = state / 'ssh-host-ed25519.pub'
        wait(host.exists)
        if not known.exists():
            known.write_text(f'[127.0.0.1]:{ssh_port} ' + host.read_text())
        wait(lambda: 'runtime running' in command('status').stdout)
        assert f"Release: {verify(package)['version']}" in command('status').stdout
    def stop():
        if process and process.poll() is None:
            process.terminate(); process.wait(timeout=20)
            assert process.returncode == 0
        run(str(binary), 'session-service-stop', '--state', str(state), timeout=10)
        # The command acknowledges a delayed shutdown; do not let the next
        # release reuse an old service that is still winding down.
        def service_stopped():
            if (state / 'session-service.pid').exists():
                return False
            with (state / 'session-service.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        wait(service_stopped)
    def health():
        with urllib.request.urlopen(f'http://127.0.0.1:{rest_port}/health', timeout=2) as response:
            return response.status == 200
    def install(name, port, websocket=False, secret=False):
        manifest = dict(application='upgrade', name=name, version='1.0.0', executable=str(previous / 'bin/kiln-example-backend'), arguments=['--port', str(port)] + (['--websocket'] if websocket else []), healthURL=f'http://127.0.0.1:{port}/health')
        if secret:
            manifest['secrets'] = {'UPGRADE_TOKEN': 'upgrade-fixture'}
        path = temporary / (name + '.json'); path.write_text(json.dumps(manifest))
        command(f'app install {path}')
    def preserved(expected):
        for relative, value in expected.items():
            assert digest(state / relative) == value, f'Persistent state changed: {relative}'
        assert digest(vault_key) == key_hash
        wait(health); wait(lambda: echo_websocket(ws_port))
        rows = {line.split()[1]: line.split()[3] for line in command('app list').stdout.splitlines() if len(line.split()) == 5 and line.split()[0] == 'upgrade'}
        assert rows == {'rest': 'running', 'websocket': 'running', 'stopped': 'stopped', 'denied': 'stopped'}, rows
        assert 'upgrade-fixture' in command('vault grants upgrade/rest').stdout
        assert command('app start upgrade/denied', check=False).returncode != 0
        with socket.socket() as probe:
            assert probe.connect_ex(('127.0.0.1', stopped_port)) != 0
    try:
        run(str(binary), 'vault', 'init', '--state', str(state), '--key-file', str(vault_key))
        run(str(binary), 'vault', 'put', 'upgrade-fixture', '--state', str(state), input='disposable-' + os.urandom(24).hex())
        launch(previous)
        install('rest', rest_port, secret=True); command('vault grant upgrade/rest upgrade-fixture'); command('app start upgrade/rest')
        install('websocket', ws_port, websocket=True); command('app start upgrade/websocket')
        install('stopped', stopped_port); command('app start upgrade/stopped'); command('app stop upgrade/stopped')
        install('denied', denied_port, secret=True)
        data = state / 'data/upgrade/rest/operator-marker'; data.write_text('persistent application data')
        files = ['applications.json', 'ssh-host-ed25519', 'ssh-host-ed25519.pub', 'identities.json', 'identities.initialized', 'vault.enc', 'vault-config.json', 'data/upgrade/rest/operator-marker']
        expected = {p: digest(state / p) for p in files}; key_hash = digest(vault_key)
        preserved(expected); stop()
        # A cold backup and separately protected key precede the upgrade. Recovery
        # never relies on silently undoing a newer incompatible state format.
        shutil.copytree(state, temporary / 'state-backup')
        shutil.copy2(vault_key, temporary / 'separate-key-backup')
        print(f"PASS previous packaged release {before['version']} established persistent fixture and cold backups", flush=True)
        launch(candidate); preserved(expected); stop()
        print(f"PASS upgrade to packaged {after['version']}: REST/WebSocket, stopped intent, SSH identity, Vault grants and data preserved", flush=True)
        launch(previous); preserved(expected); stop()
        print(f"PASS binary rollback to packaged {before['version']} on compatible persistent state", flush=True)
        for path, value in package_hashes.items():
            assert digest(Path(path)) == value, 'A package executable was overwritten'
        for relative, value in expected.items():
            assert digest(temporary / 'state-backup' / relative) == value
        assert digest(temporary / 'separate-key-backup') == key_hash
        print('PASS original and candidate executables and separate cold backups remain unchanged', flush=True)
        print('KILN_PACKAGE_UPGRADE_ROLLBACK_COMPLETE', flush=True)
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        subprocess.run([str(binary), 'session-service-stop', '--state', str(state)], capture_output=True, timeout=10)
        log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True, help='Extracted candidate package root')
    parser.add_argument('--previous', type=Path, help='Verified extracted baseline; omit to build pinned public baseline')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='kiln-package-upgrade-') as raw:
        temporary = Path(raw)
        baseline_tree = temporary / 'baseline-source'
        try:
            previous = args.previous
            if previous is None:
                subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', BASELINE_SHA], cwd=ROOT, check=True)
                subprocess.run(['git', 'worktree', 'add', '--detach', str(baseline_tree), BASELINE_SHA], cwd=ROOT, check=True)
                env = os.environ.copy()
                env.pop('GITHUB_REF_TYPE', None); env.pop('GITHUB_REF_NAME', None)
                output = temporary / 'baseline-package'
                subprocess.run(['python3', str(baseline_tree / 'scripts/package-release.py'), '--output', str(output)], cwd=baseline_tree, env=env, check=True)
                archive, = output.glob('*.tar.gz')
                expected = archive.with_suffix('.gz.sha256').read_text().split()[0]
                assert digest(archive) == expected
                extracted = temporary / 'previous'; extracted.mkdir()
                with tarfile.open(archive) as tar:
                    tar.extractall(extracted, filter='data')
                previous, = extracted.iterdir()
            rehearse(previous.resolve(), args.candidate.resolve(), temporary)
        finally:
            if baseline_tree.exists():
                subprocess.run(['git', 'worktree', 'remove', '--force', str(baseline_tree)], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
