#!/usr/bin/env python3
"""Real local OpenSSH/HTTP/WebSocket tests. Builds must already exist."""
import base64, hashlib, json, os, pathlib, signal, socket, struct, subprocess, tempfile, time, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug'))

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def wait_for(fn, seconds=10):
    deadline = time.monotonic() + seconds
    error = None
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result: return result
        except Exception as e: error = e
        time.sleep(.1)
    raise AssertionError(f'Timed out: {error}')

def http(p):
    with urllib.request.urlopen(f'http://127.0.0.1:{p}/api/hello', timeout=2) as response:
        return json.load(response)

def ws(p):
    def receive(s, count):
        data = b''
        while len(data) < count:
            more = s.recv(count-len(data))
            if not more: raise AssertionError('WebSocket closed')
            data += more
        return data
    with socket.create_connection(('127.0.0.1', p), timeout=2) as s:
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall((f'GET /ws HTTP/1.1\r\nHost: localhost:{p}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        headers = b''
        while not headers.endswith(b'\r\n\r\n'): headers += receive(s, 1)
        assert b'101 Switching Protocols' in headers, headers
        expected = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert expected in headers
        message = b'hello kiln'; mask = os.urandom(4)
        s.sendall(bytes([0x81, 0x80 | len(message)]) + mask + bytes(x ^ mask[i%4] for i,x in enumerate(message)))
        head = receive(s, 2)
        assert head == bytes([0x81, len(message)]), head
        assert receive(s, len(message)) == message
        return True

with tempfile.TemporaryDirectory(prefix='kiln-test-') as tmp:
    tmp = pathlib.Path(tmp)
    ssh_port, rest_port, ws_port = port(), port(), port()
    key = tmp/'admin'
    bad = tmp/'unauthorized'
    for path in (key, bad):
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(path)], check=True)
    state = tmp/'state'
    log = open(tmp/'runtime.log', 'w+')
    process = None
    def launch(no_ssh=False):
        args = [str(BIN/'kiln'),'up','--state',str(state)]
        args += ['--no-ssh','--console'] if no_ssh else ['--authorized-keys',str(key)+'.pub','--port',str(ssh_port)]
        return subprocess.Popen(args, stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
    def stop():
        if process and process.poll() is None:
            process.terminate(); process.wait(timeout=12)
            assert process.returncode == 0
    def scan():
        result = subprocess.run(['ssh-keyscan','-T','1','-p',str(ssh_port),'127.0.0.1'], capture_output=True, text=True)
        return '\n'.join(sorted(set(result.stdout.splitlines()))) + '\n' if 'ssh-ed25519' in result.stdout else None
    known = tmp/'known_hosts'
    def ssh(command, identity=key, check=True, shell=False):
        args=['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o',f'UserKnownHostsFile={known}','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=2','-i',str(identity),'-p',str(ssh_port)]
        if shell: args += ['-T']
        args += ['admin@127.0.0.1']
        if not shell: args += [command]
        result = subprocess.run(args, input=command if shell else None, capture_output=True, text=True, timeout=12)
        if check: assert result.returncode == 0, (result.stdout, result.stderr)
        return result
    def install(name, p, websocket=False):
        manifest = {'application':'storefront','name':name,'version':'0.1.0','executable':str(BIN/'kiln-example-backend'), 'arguments':['--port',str(p)] + (['--websocket'] if websocket else []), 'healthURL':f'http://127.0.0.1:{p}/health'}
        path = tmp/f'{name}.json'; path.write_text(json.dumps(manifest))
        ssh(f'app install {path}'); ssh(f'app start storefront/{name}')
    def pid(name):
        line = next(x for x in ssh('app list').stdout.splitlines() if len(x.split()) == 5 and x.split()[1] == name)
        return int(line.split()[-1])
    try:
        process=launch(); first=wait_for(scan); known.write_text(first)
        assert 'runtime running' in ssh('status').stdout
        assert ssh('status', identity=bad, check=False).returncode == 255
        assert ssh('does-not-exist',check=False).returncode == 2
        shell=ssh('status\nhelp\nexit\n',shell=True)
        assert 'Welcome to Kiln' in shell.stdout and 'runtime running' in shell.stdout
        print('PASS: public-key SSH, negative authentication, exec status and plain interactive shell', flush=True)
        install('rest',rest_port); wait_for(lambda: http(rest_port)); old_pid=pid('rest')
        install('websocket',ws_port,True); wait_for(lambda: ws(ws_port))
        assert pid('rest') == old_pid
        assert 'healthy' in ssh('app health storefront/rest').stdout
        print('PASS: install WebSocket module without restarting REST module', flush=True)
        os.kill(old_pid, signal.SIGKILL)
        wait_for(lambda: 'exited' in ssh('app list').stdout)
        assert ws(ws_port) and process.poll() is None
        ssh('app restart storefront/rest'); wait_for(lambda: http(rest_port))
        print('PASS: real process crash contained; other module and SSH survive; manual restart works', flush=True)
        stop(); process=launch(); second=wait_for(scan)
        assert first == second, 'Host key changed'
        wait_for(lambda: http(rest_port)); wait_for(lambda: ws(ws_port))
        print('PASS: persistent host identity and application restore', flush=True)
        stop(); process=launch(no_ssh=True)
        wait_for(lambda: http(rest_port)); wait_for(lambda: ws(ws_port))
        process.stdin.write('status\n'); process.stdin.flush()
        wait_for(lambda: 'KilnSSH disabled' in (tmp/'runtime.log').read_text())
        with socket.socket() as s:
            assert s.connect_ex(('127.0.0.1',ssh_port)) != 0
        print('PASS: runtime and modules work with SSH disabled', flush=True)
        stop()
    except Exception:
        log.flush(); print((tmp/'runtime.log').read_text())
        raise
    finally:
        if process and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=12)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
