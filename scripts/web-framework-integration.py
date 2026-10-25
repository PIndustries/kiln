#!/usr/bin/env python3
"""Disposable real HTTP/WebSocket acceptance for KilnWeb; standard library only."""
import base64
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug'))
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
origin = f'http://127.0.0.1:{port}'

def http(method, path, body=None, cookie=None, extra=None):
    connection = HTTPConnection('127.0.0.1', port, timeout=5)
    headers = dict(extra or {})
    if cookie:
        headers['Cookie'] = cookie
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    result = response.status, dict(response.getheaders()), response.read().decode()
    connection.close()
    return result

def mounted():
    code, headers, html = http('GET', '/counter')
    assert code == 200 and '<strong id="count">0</strong>' in html
    assert 'HttpOnly; SameSite=Strict' in headers['set-cookie']
    assert "script-src 'self'" in headers['content-security-policy']
    return (headers['set-cookie'].split(';')[0], re.search(r'data-ticket="([^"]+)"', html)[1], re.search(r'data-csrf="([^"]+)"', html)[1])

class Live:
    def __init__(self, cookie, ticket, request_origin=origin, accept=True):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall((f'GET /__kiln/live/{ticket} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: {request_origin}\r\nCookie: {cookie}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        header = b''
        while not header.endswith(b'\r\n\r\n'):
            part = self.socket.recv(1)
            if not part and not accept:
                self.close(); return
            assert part, header
            header += part
        if not accept:
            assert b'101 Switching Protocols' not in header
            self.close()
        else:
            if b'101 Switching Protocols' not in header:
                self.close(); raise AssertionError(header)
    def close(self):
        self.socket.close()
    def exact(self, count):
        result = b''
        while len(result) < count:
            data = self.socket.recv(count - len(result))
            if not data:
                raise EOFError('Live connection closed')
            result += data
        return result
    def receive(self):
        first, second = self.exact(2)
        length = second & 127
        if length == 126:
            length = struct.unpack('!H', self.exact(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.exact(8))[0]
        assert length <= 1048576
        data = self.exact(length)
        if first & 15 == 8:
            raise EOFError('Server closed live connection')
        if first & 15 == 9:
            self.send_frame(0x8a, data)
            return self.receive()
        if first & 15 == 10:
            return self.receive()
        assert first & 15 == 1
        return json.loads(data)
    def event(self, sequence, name, csrf, values=None):
        data = json.dumps(dict(sequence=sequence, name=name, csrf=csrf, values=values or {})).encode()
        self.send_frame(0x81, data)
    def send_frame(self, opcode, data):
        mask = os.urandom(4)
        header = bytes([opcode, 0x80 | len(data)]) if len(data) < 126 else bytes([opcode, 0xfe]) + struct.pack('!H', len(data))
        self.socket.sendall(header + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(data)))
    def until_count(self, expected):
        for _ in range(12):
            update = self.receive()
            assert update['version'] == 1
            if f'<strong id="count">{expected}</strong>' in update['html']:
                return update
        raise AssertionError('Expected server state never arrived')

def reconnect(session):
    deadline = time.monotonic() + 5
    while True:
        try:
            return Live(*session[:2])
        except AssertionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(.05)

with tempfile.TemporaryDirectory(prefix='kiln-web-') as td:
    clients = []
    with open(Path(td) / 'web.log', 'w+') as log:
        process = subprocess.Popen([str(BIN / 'kiln-example-web'), '--port', str(port)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    if http('GET', '/health')[0] == 200:
                        break
                except OSError:
                    pass
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(.05)
            a, b = mounted(), mounted()
            assert http('GET', '/hello/%3Cscript%3E')[2] == '<h1>Hello, &lt;script&gt;</h1>'
            assert http('GET', '/unknown')[0] == 404
            assert http('HEAD', '/health')[2] == ''
            assert http('GET', '/__kiln/live.js')[0] == 200
            assert http('GET', '/health', extra={'Host': 'evil.test'})[0] == 403
            print('PASS real HTTP: complete SSR HTML, parameter routes, escaping, assets, HEAD, 404 and host boundary', flush=True)
            left, right = Live(*a[:2]), Live(*b[:2])
            clients += [left, right]
            left.until_count(0); right.until_count(0)
            left.event(1, 'increment', a[2])
            left.until_count(1); right.until_count(1)
            right.event(1, 'rename', b[2], {'message': '<script>unsafe()</script>'})
            for client in [left, right]:
                while True:
                    update = client.receive()
                    if '&lt;script&gt;unsafe()&lt;/script&gt;' in update['html']:
                        assert '<script>unsafe()' not in update['html']
                        break
            print('PASS real WebSocket: two independent browsers receive server-rendered pub/sub updates and escaped form events', flush=True)
            code = http('POST', '/counter/increment', cookie=a[0], extra={'Origin': origin, 'X-CSRF-Token': a[2]})[0]
            assert code == 200
            left.until_count(2); right.until_count(2)
            assert http('POST', '/counter/increment', cookie=a[0], extra={'Origin': origin, 'X-CSRF-Token': 'forged'})[0] == 403
            assert http('POST', '/counter/increment', cookie=a[0], extra={'Origin': 'http://evil.test', 'X-CSRF-Token': a[2]})[0] == 403
            Live(b[0], a[1], accept=False)
            Live(a[0], a[1], request_origin='http://evil.test', accept=False)
            print('PASS HTTP action broadcasts into live views; forged CSRF, cross-origin and cross-browser attachments rejected', flush=True)
            left.close()
            restored = reconnect(a); clients.append(restored)
            assert restored.until_count(2)['sequence'] == 1
            restored.event(1, 'increment', a[2])  # Duplicate sequence must not mutate.
            try:
                while True:
                    restored.receive()
            except (EOFError, ConnectionResetError):
                pass
            restored2 = reconnect(a); clients.append(restored2)
            assert restored2.until_count(2)['sequence'] == 1
            restored2.event(2, 'increment', a[2])
            restored2.until_count(3); right.until_count(3)
            print('PASS reconnect retains view state; duplicate events cannot replay a mutation; fresh sequential events work', flush=True)
            code, headers, html = http('GET', '/')
            csrf = re.search(r'name="_csrf" value="([^"]+)"', html)[1]
            assert http('POST', '/greet', body=f'_csrf={csrf}&name=%3Cimg%3E', cookie=headers['set-cookie'].split(';')[0], extra={'Origin': origin, 'Content-Type': 'application/x-www-form-urlencoded'})[0] == 200
        except Exception:
            log.flush(); print(Path(log.name).read_text(), flush=True)
            raise
        finally:
            for client in clients:
                client.close()
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)

# Exercise the real supervisor's stable ingress and separate worker health path.
def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='kiln-web-managed-') as td:
    root = Path(td)
    state, key = root / 'state', root / 'admin'
    management, port, worker_a, worker_b = free_port(), free_port(), free_port(), free_port()
    origin = f'http://127.0.0.1:{port}'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    with (root / 'runtime.log').open('w+') as log:
        runtime = subprocess.Popen([str(BIN / 'kiln'), 'up', '--state', str(state), '--authorized-keys', str(key) + '.pub', '--port', str(management)], stdout=log, stderr=log)
        known = root / 'known'
        base = ['ssh', '-F', '/dev/null', '-o', 'LogLevel=ERROR', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-i', str(key), '-p', str(management), 'admin@127.0.0.1']
        def command(text):
            result = subprocess.run(base + [text], capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (text, result.stdout, result.stderr)
            return result.stdout
        try:
            deadline = time.monotonic() + 15
            while not (state / 'ssh-host-ed25519.pub').exists():
                assert time.monotonic() < deadline and runtime.poll() is None
                time.sleep(.05)
            known.write_text(f'[127.0.0.1]:{management} ' + (state / 'ssh-host-ed25519.pub').read_text())
            while subprocess.run(base + ['status'], capture_output=True, timeout=3).returncode:
                assert time.monotonic() < deadline
                time.sleep(.05)
            manifest = root / 'web.json'
            for version, backend in [('1', worker_a), ('2', worker_b)]:
                manifest.write_text(json.dumps(dict(application='web', name='site', version=version, executable=str(BIN / 'kiln-example-web'), arguments=['--origin', origin], healthURL=f'http://127.0.0.1:{backend}/__kiln/health', ingressPort=port)))
                assert f'web/site@{version}' in command('app deploy ' + str(manifest))
                code, headers, html = http('GET', '/counter')
                assert code == 200 and 'data-ticket=' in html
                assert 'HTTP 200' in command('app health web/site')
                cookie = headers['set-cookie'].split(';')[0]
                ticket = re.search(r'data-ticket="([^"]+)"', html)[1]
                csrf = re.search(r'data-csrf="([^"]+)"', html)[1]
                live = Live(cookie, ticket, request_origin=origin)
                try:
                    live.until_count(0)
                    live.event(1, 'increment', csrf)
                    live.until_count(1)
                finally:
                    live.close()
                internal = HTTPConnection('127.0.0.1', backend, timeout=5)
                internal.request('GET', '/counter')
                response = internal.getresponse()
                assert response.status == 403
                response.read(); internal.close()
            assert 'web/site@1' in command('app rollback web/site')
            assert http('GET', '/counter')[0] == 200 and runtime.poll() is None
            print('PASS managed Kiln worker: stable public ingress, explicit public Origin, isolated liveness probe, live WebSocket events, upgrade and rollback', flush=True)
        except Exception:
            log.flush(); print((root / 'runtime.log').read_text(), flush=True)
            raise
        finally:
            if runtime.poll() is None:
                runtime.terminate()
            runtime.wait(timeout=15)
            subprocess.run([str(BIN / 'kiln'), 'session-service-stop', '--state', str(state)], capture_output=True, timeout=8)
print('KILN_WEB_FRAMEWORK_COMPLETE', flush=True)
