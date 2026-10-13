#!/usr/bin/env python3
"""Real SSH recovery: unhealthy HTTP worker, reconnect, approval, verification and cold restore."""
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug'))

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def wait(check, seconds=20):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            value = check()
            if value: return value
        except Exception as error:
            last = error
        time.sleep(.1)
    raise AssertionError(f'Timed out: {last}')

with tempfile.TemporaryDirectory(prefix='kiln-recovery-e2e-') as temporary:
    root = Path(temporary)
    state, key, known = root/'state', root/'admin', root/'known_hosts'
    ssh_port, http_port = free_port(), free_port()
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    worker = root/'worker.sh'
    # The fixture runs in Kiln's separate worker process. First generation is
    # deliberately unhealthy; the second generation returns HTTP 200.
    python = '''import http.server, os, pathlib, sys
p = pathlib.Path(os.environ['KILN_DATA_DIR']) / 'starts'
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200 if n >= 2 else 503); self.send_header('Content-Length', '7'); self.send_header('Connection', 'close'); self.end_headers(); self.wfile.write(b'fixture')
 def log_message(self, *args): pass
class Server(http.server.ThreadingHTTPServer):
 allow_reuse_address = True
Server(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
'''
    source = root/'worker.py'; source.write_text(python)
    worker.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(source)) + ' "$@"\n')
    worker.chmod(0o700)
    manifest = root/'module.json'
    manifest.write_text(json.dumps(dict(application='demo', name='api', version='1', executable=str(worker), arguments=[str(http_port)], healthURL=f'http://127.0.0.1:{http_port}/health')))
    log = (root/'runtime.log').open('w+')
    process = None
    def start():
        return subprocess.Popen([str(BIN/'kiln'), 'up', '--state', str(state), '--authorized-keys', str(key)+'.pub', '--port', str(ssh_port)], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    def scan():
        result = subprocess.run(['ssh-keyscan', '-T', '1', '-p', str(ssh_port), '127.0.0.1'], capture_output=True, text=True)
        return result.stdout if 'ssh-ed25519' in result.stdout else None
    def ssh(command, check=True):
        result = subprocess.run(['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-o', 'ConnectTimeout=2', '-i', str(key), '-p', str(ssh_port), 'admin@127.0.0.1', command], capture_output=True, text=True, timeout=12)
        if check: assert result.returncode == 0, (command, result.stdout, result.stderr)
        return result.stdout
    def record(task_id):
        return next(r for r in json.loads((state/'ai-recovery.json').read_text())['records'] if r['id'] == task_id)
    try:
        process = start(); known.write_text(wait(scan))
        ssh('app install ' + str(manifest)); ssh('app start demo/api')
        starts = state/'data/demo/api/starts'
        wait(lambda: starts.read_text() == '1')
        receipt = ssh('ai recovery new demo/api')
        task_id = re.search(r'recovery:([0-9a-f-]{36})', receipt).group(1)
        wait(lambda: record(task_id)['state'] == 'awaitingApproval')
        starts = state/'data/demo/api/starts'
        assert starts.read_text() == '1'
        # Every exec uses a fresh SSH connection. Approval survives disconnect.
        pending = ssh('ai task show recovery:' + task_id)
        assert 'awaitingApproval' in pending and 'unhealthy' in pending
        ssh('ai approve recovery:' + task_id)
        ssh('ai approve recovery:' + task_id)
        wait(lambda: record(task_id)['state'] == 'recovered', seconds=40)
        assert starts.read_text() == '2', 'duplicate approval restarted worker twice'
        evidence = record(task_id)
        assert evidence['after']['health'] == 'healthy'
        operation = json.loads((state/'operations'/f'{task_id}.json').read_text())
        assert operation['state'] == 'succeeded'
        assert operation['resultGeneration'] == evidence['after']['generation']
        print('PASS recovery: fresh SSH sessions, one approval effect and verified healthy replacement', flush=True)
        process.terminate(); assert process.wait(timeout=15) == 0
        process = start(); wait(lambda: 'runtime running' in ssh('status', check=False))
        wait(lambda: starts.read_text() == '3')
        assert '[recovered]' in ssh('ai task show recovery:' + task_id)
        ssh('ai approve recovery:' + task_id)
        assert starts.read_text() == '3', 'restored approval replayed an operation'
        print('PASS recovery: cold restore retains evidence and does not replay approval', flush=True)
        print('KILN_AI_RECOVERY_COMPLETE', flush=True)
    except Exception:
        # Disposable fixture state only; never collect real provider configuration.
        for diagnostic in [state/'ai-recovery.json', *state.glob('logs/**/*.log')]:
            if diagnostic.is_file():
                print(f'Fixture diagnostic {diagnostic.name}:', file=sys.stderr)
                print(diagnostic.read_text(errors='replace')[-12000:], file=sys.stderr)
        log.flush(); log.seek(0); print(log.read()[-12000:], file=sys.stderr)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        log.close()
