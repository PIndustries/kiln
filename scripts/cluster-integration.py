#!/usr/bin/env python3
"""Two real native Kiln nodes, pinned SSH peer transport and durable operations.

Uses loopback only, generated fixture keys and temporary state. No hosted API.
"""
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug')).resolve()
PORTS = set()

def port(kind=socket.SOCK_STREAM):
    while True:
        with socket.socket(socket.AF_INET, kind) as s:
            s.bind(('127.0.0.1', 0)); value = s.getsockname()[1]
        if value not in PORTS:
            PORTS.add(value); return value

def wait(fn, seconds=20):
    deadline = time.monotonic() + seconds; last = None
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result: return result
        except Exception as error: last = error
        time.sleep(.05)
    raise AssertionError(f'Timed out: {last}')

def health(p):
    with urllib.request.urlopen(f'http://127.0.0.1:{p}/health', timeout=1) as response:
        return response.status == 200

def closed(p):
    with socket.socket() as s:
        s.settimeout(.2); return s.connect_ex(('127.0.0.1', p)) != 0

with tempfile.TemporaryDirectory(prefix='kiln-cluster-') as folder:
    folder = pathlib.Path(folder); key = folder / 'admin'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    clients = []
    discovery_port = port(socket.SOCK_DGRAM) if os.environ.get('KILN_TEST_MULTICAST') == '1' else None
    class Node:
        def __init__(self, name):
            self.state = folder / name; self.sshport = port(); self.peerport = port()
            self.log = open(folder / (name + '.log'), 'w+')
            self.known = folder / (name + '.known'); self.process = None
            self.base = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=2', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={self.known}', '-i', str(key), '-p', str(self.sshport), 'admin@127.0.0.1']
        def launch(self):
            args = [str(BIN / 'kiln'), 'up', '--state', str(self.state), '--authorized-keys', str(key) + '.pub', '--port', str(self.sshport), '--cluster-port', str(self.peerport)]
            if discovery_port is not None:
                args += ['--cluster-host', '0.0.0.0', '--discovery-port', str(discovery_port)]
            self.process = subprocess.Popen(args, stdout=self.log, stderr=self.log)
            hostkey = self.state / 'ssh-host-ed25519.pub'; wait(hostkey.exists)
            self.known.write_text(f'[127.0.0.1]:{self.sshport} ' + hostkey.read_text())
            wait(lambda: self.command('status').returncode == 0)
        def command(self, command, ok=True):
            result = subprocess.run(self.base + [command], text=True, capture_output=True, timeout=25)
            if ok: assert result.returncode == 0, (command, result.stdout, result.stderr)
            return result
        def fingerprint(self):
            return re.search(r'SHA256:[A-Za-z0-9+/]+', self.command('node identity').stdout).group()
        def stop(self):
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(timeout=20)
                except subprocess.TimeoutExpired: self.process.kill(); self.process.wait(timeout=5)
        def cleanup(self):
            self.stop()
            subprocess.run([str(BIN / 'kiln'), 'session-service-stop', '--state', str(self.state)], capture_output=True, timeout=10)
            self.log.close()
    a, b = Node('a'), Node('b')
    try:
        a.launch(); b.launch(); af, bf = a.fingerprint(), b.fingerprint(); assert af != bf
        if discovery_port is not None:
            wait(lambda: bf in a.command('node adoption list').stdout and af in b.command('node adoption list').stdout, seconds=15)
            assert bf not in a.command('node list').stdout
            print('PASS: optional LAN multicast discovers both candidates without adopting either', flush=True)
        backend_port = port()
        manifest = folder / 'module.json'
        manifest.write_text(json.dumps(dict(application='cluster-demo', name='api', version='1.0.0', executable=str(BIN / 'kiln-example-backend'), arguments=['--port', str(backend_port)], healthURL=f'http://127.0.0.1:{backend_port}/health')))
        b.command(f'app install {manifest}')
        a.command(f'node discover 127.0.0.1 {b.peerport}')
        assert bf in a.command('node adoption list').stdout
        assert a.command(f'node start {bf} cluster-demo/api', False).returncode != 0
        assert closed(backend_port)
        a.command(f'node accept {bf}')
        assert a.command(f'node start {bf} cluster-demo/api', False).returncode != 0
        assert closed(backend_port)
        b.command(f'node discover 127.0.0.1 {a.peerport}'); b.command(f'node accept {af}')
        print('PASS: explicit discovery is untrusted; one-way adoption cannot activate a remote module', flush=True)
        result = a.command(f'node start {bf} cluster-demo/api').stdout
        operation_id = re.search(r'Request: ([0-9a-f-]{36})', result).group(1)
        wait(lambda: health(backend_port))
        assert 'cluster-demo' in a.command(f'node status {bf}').stdout
        assert 'reachable' in a.command('node list').stdout
        assert 'completed' in a.command(f'node receipt {bf} {operation_id}').stdout
        assert operation_id in a.command('node operations').stdout
        a.command(f'node stop {bf} cluster-demo/api'); wait(lambda: closed(backend_port))
        a.command(f'node start {bf} cluster-demo/api'); wait(lambda: health(backend_port))
        a.command(f'node restart {bf} cluster-demo/api'); wait(lambda: health(backend_port))
        print('PASS: mutually pinned native SSH runs typed remote inventory/start/stop/restart and returns durable receipts', flush=True)
        b.command(f'node revoke {af}')
        assert a.command(f'node stop {bf} cluster-demo/api', False).returncode != 0
        assert health(backend_port)
        b.command(f'node discover 127.0.0.1 {a.peerport}'); b.command(f'node accept {af}')
        print('PASS: revocation denies subsequent remote control without stopping healthy workloads', flush=True)

        # Keep receiver restart in flight for the guardian's graceful timeout.
        worker = folder / 'stubborn.py'
        worker.write_text('#!' + sys.executable + '\nimport os,pathlib,signal,time\np=pathlib.Path(os.environ["KILN_DATA_DIR"])\ndef term(s,f): (p/"term").write_text("received")\nsignal.signal(signal.SIGTERM,term)\nn=p/"starts"\nn.write_text(str(int(n.read_text())+1 if n.exists() else 1))\nwhile True: time.sleep(.05)\n')
        worker.chmod(0o700)
        stubborn_manifest = folder / 'stubborn.json'
        stubborn_manifest.write_text(json.dumps(dict(application='cluster-demo', name='stubborn', version='1.0.0', executable=str(worker), arguments=[])))
        b.command(f'app install {stubborn_manifest}'); b.command('app start cluster-demo/stubborn')
        starts = b.state / 'data/cluster-demo/stubborn/starts'; wait(starts.exists)
        old_ids = {p.name for p in (a.state / 'cluster/outbound').glob('*.json')}
        client = subprocess.Popen(a.base + [f'node restart {bf} cluster-demo/stubborn'], stdout=subprocess.PIPE, stderr=subprocess.PIPE); clients.append(client)
        def new_request():
            new = [p for p in (a.state / 'cluster/outbound').glob('*.json') if p.name not in old_ids]
            return new[0] if len(new) == 1 else None
        request_path = wait(new_request); pending_id = request_path.stem
        receipt_file = b.state / 'cluster/receipts' / request_path.name
        wait(lambda: receipt_file.exists() and json.loads(receipt_file.read_text())['response']['state'] == 'started')
        wait(lambda: (b.state / 'data/cluster-demo/stubborn/term').exists())
        a.process.kill(); a.process.wait(timeout=5); client.communicate(timeout=5)
        wait(lambda: json.loads(receipt_file.read_text())['response']['state'] == 'completed')
        wait(lambda: starts.read_text() == '2')
        a.launch(); assert a.fingerprint() == af
        pending_line = next(line for line in a.command('node operations').stdout.splitlines() if line.startswith(pending_id + ' '))
        assert pending_line.endswith('unconfirmed'), pending_line
        assert 'completed' in a.command(f'node receipt {bf} {pending_id}').stdout
        reconciled_line = next(line for line in a.command('node operations').stdout.splitlines() if line.startswith(pending_id + ' '))
        assert reconciled_line.endswith('completed'), reconciled_line
        time.sleep(.3); assert starts.read_text() == '2', 'Sender restart or receipt lookup replayed mutation'
        b.command('app stop cluster-demo/stubborn')
        print('PASS: sender SIGKILL during remote restart preserves outbound ID; receiver completes once; sender restores and queries without replay', flush=True)
        b.stop()
        assert a.command(f'node status {bf}', False).returncode != 0
        assert 'unreachable' in a.command('node list').stdout
        b.launch(); assert b.fingerprint() == bf; wait(lambda: health(backend_port))
        assert 'completed' in a.command(f'node receipt {bf} {operation_id}').stdout
        print('PASS: offline peer is reported honestly; identity, mutual trust, module desired state and receipts survive both-node restart', flush=True)
    except Exception:
        for node in (a, b):
            node.log.flush(); print((folder / (node.state.name + '.log')).read_text(), flush=True)
        raise
    finally:
        for client in clients:
            if client.poll() is None: client.kill()
            client.communicate(timeout=5)
        a.cleanup(); b.cleanup()
