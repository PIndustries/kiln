#!/usr/bin/env python3
"""Real OpenSSH, TCP ingress, HTTP/WS release switching and persisted rollback."""
import base64, concurrent.futures, http.server, json, os, pathlib, socket, subprocess, tempfile, threading, time, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug'))
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
def wait(fn, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = fn()
            if value: return value
        except Exception: pass
        time.sleep(.05)
    raise AssertionError('Timed out')
def version(p):
    with urllib.request.urlopen(f'http://127.0.0.1:{p}/api/version', timeout=2) as r: return json.load(r)['version']
def receive(s, n):
    b = b''
    while len(b) < n:
        chunk = s.recv(n-len(b)); assert chunk, 'Unexpected EOF'; b += chunk
    return b
def websocket(p):
    s = socket.create_connection(('127.0.0.1', p), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(f'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
    head = b''
    while not head.endswith(b'\r\n\r\n'): head += receive(s, 1)
    assert b'101 Switching Protocols' in head, head
    return s
def echo(s):
    payload = b'old connection still works'; mask = os.urandom(4)
    s.sendall(bytes([129, 128+len(payload)]) + mask + bytes(x ^ mask[i%4] for i,x in enumerate(payload)))
    assert receive(s, 2) == bytes([129, len(payload)])
    assert receive(s, len(payload)) == payload
with tempfile.TemporaryDirectory(prefix='kiln-deploy-') as tmp:
    tmp = pathlib.Path(tmp); key = tmp/'admin'; state = tmp/'state'
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)], check=True)
    sshport, ingress, tunnelport = port(), port(), port()
    log = open(tmp/'runtime.log', 'w+')
    process = tunnel = None; held = ws = None
    stop_traffic = threading.Event(); errors = []; observed = []
    def launch():
        return subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--port',str(sshport)], stdout=log, stderr=log)
    known = tmp/'known'
    base = ['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}','-i',str(key),'-p',str(sshport)]
    def command(c, check=True):
        r = subprocess.run(base+['admin@127.0.0.1', c], capture_output=True, text=True, timeout=40)
        if check: assert r.returncode == 0, (c,r.stdout,r.stderr)
        return r
    def manifest(v, health='/health', executable=None):
        p = port(); path = tmp/f'{v}.json'
        path.write_text(json.dumps(dict(application='storefront',name='api',version=v,executable=str(executable or BIN/'kiln-example-backend'),arguments=['--port',str(p),'--websocket'],healthURL=f'http://127.0.0.1:{p}{health}',ingressPort=ingress)))
        return path
    def traffic():
        while not stop_traffic.is_set():
            try: observed.append(version(tunnelport))
            except Exception as e: errors.append(str(e))
            time.sleep(.01)
    try:
        process = launch()
        def scan():
            r = subprocess.run(['ssh-keyscan','-T','1','-p',str(sshport),'127.0.0.1'],capture_output=True,text=True)
            return r.stdout if 'ssh-ed25519' in r.stdout else None
        known.write_text(wait(scan)); wait(lambda: command('status').returncode == 0)
        first, second = manifest('1.0.0'), manifest('2.0.0')
        command(f'app deploy {first}'); assert version(ingress) == '1.0.0'
        tunnel = subprocess.Popen(base+['-N','-o','ExitOnForwardFailure=yes','-L',f'127.0.0.1:{tunnelport}:127.0.0.1:{ingress}','admin@127.0.0.1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        wait(lambda: version(tunnelport) == '1.0.0')
        print('PASS: deploy healthy Swift release; encrypted authenticated OpenSSH ingress tunnel',flush=True)
        thread = threading.Thread(target=traffic); thread.start()
        held = socket.create_connection(('127.0.0.1',ingress),timeout=3)
        held.sendall(b'GET /api/version HTTP/1.1\r\nHost: localhost\r\n')
        ws = websocket(ingress); echo(ws)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            update = pool.submit(command, f'app deploy {second}')
            wait(lambda: version(tunnelport) == '2.0.0')
            assert not update.done(), 'Update should drain old clients'
            assert command('app stop storefront/api',False).returncode == 1
            held.sendall(b'\r\n'); result = b''
            while True:
                chunk = held.recv(4096)
                if not chunk: break
                result += chunk
            assert b'1.0.0' in result, result
            echo(ws); ws.close(); ws=None; held.close(); held=None
            update.result()
        assert command('app health storefront/api').returncode == 0
        print('PASS: update switches new requests; in-flight HTTP and existing WebSocket remain on old worker; concurrent stop rejected',flush=True)
        for bad in [manifest('bad-health', '/missing'), manifest('bad-process', executable='/usr/bin/false')]:
            assert command(f'app deploy {bad}',False).returncode == 1
            assert version(ingress) == '2.0.0'
        class Redirect(http.server.BaseHTTPRequestHandler):
            followed = 0
            def do_GET(self):
                if self.path == '/ready':
                    Redirect.followed += 1; self.send_response(200)
                else:
                    self.send_response(302); self.send_header('Location', '/ready')
                self.end_headers()
            def log_message(self, *args): pass
        redirect = http.server.HTTPServer(('127.0.0.1',0), Redirect)
        redirect_thread = threading.Thread(target=redirect.serve_forever); redirect_thread.start()
        try:
            bad = manifest('bad-redirect', executable='/bin/sleep')
            data = json.loads(bad.read_text()); data['arguments'] = ['60']
            data['healthURL'] = f'http://127.0.0.1:{redirect.server_port}/health'
            bad.write_text(json.dumps(data))
            assert command(f'app deploy {bad}', False).returncode == 1
            assert Redirect.followed == 0
        finally:
            redirect.shutdown(); redirect.server_close(); redirect_thread.join()
        command('app rollback storefront/api'); assert version(tunnelport) == '1.0.0'
        assert command(f'app deploy {second}',False).returncode == 1  # retained versions are immutable
        assert 'Previous: 2.0.0' in command('app releases storefront/api').stdout
        stop_traffic.set(); thread.join()
        assert not errors, errors
        assert {'1.0.0','2.0.0'} <= set(observed), set(observed)
        print(f'PASS: failed candidates preserve active release; rollback; {len(observed)} concurrent encrypted requests, zero failures',flush=True)
        tunnel.terminate(); tunnel.wait(timeout=5); tunnel=None
        process.terminate(); process.wait(timeout=12); assert process.returncode == 0
        process=launch(); wait(lambda: version(ingress) == '1.0.0')
        wait(lambda: command('status').returncode == 0)  # Restore finishes before SSH is exposed.
        command('app rollback storefront/api'); assert version(ingress) == '2.0.0'
        print('PASS: active/previous releases and stable ingress survive clean runtime restart',flush=True)
    finally:
        stop_traffic.set()
        if held: held.close()
        if ws: ws.close()
        if tunnel and tunnel.poll() is None: tunnel.terminate(); tunnel.wait(timeout=5)
        if process and process.poll() is None: process.terminate(); process.wait(timeout=15)
        if (state/'session-service.pid').exists(): subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
        if errors: print(errors)
        log.seek(0)
        if process and process.returncode not in (0,None): print(log.read())
        log.close()
