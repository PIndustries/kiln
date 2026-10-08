#!/usr/bin/env python3
"""Real supervisor SIGKILL recovery. No host reboot or external credentials required.

Run against already-built binaries using KILN_BIN_DIR. Every process/port/state
belongs to a temporary fixture. The task recovery case deliberately seeds the
persisted crash state; it does not claim to run a live provider task.
"""
import base64
import hashlib
import fcntl
import json
import os
import pathlib
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug')).resolve()
ISSUED_PORTS = set()


def port():
    while True:
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            chosen = s.getsockname()[1]
        if chosen not in ISSUED_PORTS:
            ISSUED_PORTS.add(chosen)
            return chosen


def wait(fn, seconds=15):
    deadline = time.monotonic() + seconds
    error = None
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except Exception as exc:
            error = exc
        time.sleep(.05)
    raise AssertionError(f'Timed out: {error}')


def version(p):
    with urllib.request.urlopen(f'http://127.0.0.1:{p}/api/version', timeout=1) as r:
        return json.load(r)['version']


def closed(p):
    with socket.socket() as s:
        s.settimeout(.2)
        return s.connect_ex(('127.0.0.1', p)) != 0


def receive(s, count):
    data = b''
    while len(data) < count:
        part = s.recv(count - len(data))
        assert part, 'WebSocket closed unexpectedly'
        data += part
    return data


def websocket(p):
    s = socket.create_connection(('127.0.0.1', p), timeout=2)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(f'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
    header = b''
    while not header.endswith(b'\r\n\r\n'):
        header += receive(s, 1)
    assert b'101 Switching Protocols' in header, header
    return s


def echo(s):
    payload = b'crash-recovery'; mask = os.urandom(4)
    s.sendall(bytes([129, 128 + len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    assert receive(s, 2) == bytes([129, len(payload)])
    assert receive(s, len(payload)) == payload
    return True


with tempfile.TemporaryDirectory(prefix='kiln-crash-') as directory:
    tmp = pathlib.Path(directory).resolve(); state = tmp / 'state'; key = tmp / 'admin'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    subprocess.run([str(BIN / 'kiln'), 'vault', 'init', '--state', str(state), '--key-file', str(tmp / 'master')], check=True, capture_output=True)
    secret = uuid.uuid4().hex
    subprocess.run([str(BIN / 'kiln'), 'vault', 'put', 'recovery-test', '--state', str(state)], input=secret, text=True, check=True, capture_output=True)
    sshport, restport, wsport, stoppedport, ingress = [port() for _ in range(5)]
    known = tmp / 'known'; log = open(tmp / 'runtime.log', 'w+')
    process = None; held = None; clients = []
    base = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=2', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-i', str(key), '-p', str(sshport), 'admin@127.0.0.1']

    def launch():
        return subprocess.Popen([str(BIN / 'kiln'), 'up', '--state', str(state), '--authorized-keys', str(key) + '.pub', '--port', str(sshport)], stdout=log, stderr=log)

    def command(text):
        r = subprocess.run(base + [text], text=True, capture_output=True, timeout=20)
        assert r.returncode == 0, (text, r.stdout, r.stderr)
        assert secret not in r.stdout + r.stderr
        return r.stdout

    def ready():
        host = state / 'ssh-host-ed25519.pub'
        wait(host.exists)
        known.write_text(f'[127.0.0.1]:{sshport} ' + host.read_text())
        wait(lambda: 'runtime running' in command('status'))

    def workers():
        # Match only the unique staged executable prefix of this fixture, never
        # arbitrary ledger PIDs. Also safe for failure cleanup after a crash.
        result = subprocess.run(['ps', '-axo', 'pid=,args='], capture_output=True, text=True, check=True)
        found = {}
        prefix = str(state / 'releases') + '/'
        for line in result.stdout.splitlines():
            columns = line.strip().split(None, 1)
            argv = columns[1].split() if len(columns) == 2 else []
            executable = os.path.realpath(argv[0]) if argv else ''
            interpreted_fixture = (len(argv) > 1 and os.path.realpath(argv[1]).startswith(prefix))
            if executable.startswith(prefix) or interpreted_fixture:
                found[int(columns[0])] = columns[1]
        return found

    def manifest(name, v, p, managed=False, health='/health'):
        path = tmp / f'{name}-{v}.json'
        data = dict(application='crash', name=name, version=v, executable=str(BIN / 'kiln-example-backend'), arguments=['--port', str(p), '--websocket'], healthURL=f'http://127.0.0.1:{p}{health}', restartPolicy='always')
        if managed:
            data['ingressPort'] = ingress
        path.write_text(json.dumps(data))
        return path

    def crash():
        global process
        process.kill(); process.wait(timeout=5)
        assert process.returncode == -signal.SIGKILL

    def restore(expected, old):
        global process
        process = launch(); ready()
        wait(lambda: len(workers()) == expected)
        assert not set(old) & set(workers()), 'Old worker survived reconciliation'
        assert closed(stoppedport), 'Explicitly stopped worker restarted'
        rows = [line.split() for line in command('app list').splitlines()]
        assert sum(len(row) == 5 and row[3] == 'running' for row in rows) == expected, rows

    def start_deploy(path):
        client = subprocess.Popen(base + [f'app deploy {path}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        clients.append(client)
        return client

    try:
        # A supervisor can die between child spawn and the PID acknowledgement.
        # A closed reader must not SIGPIPE-kill its guardian and orphan the child.
        ack_worker = state / 'releases/ack/worker/1/app'
        ack_worker.parent.mkdir(parents=True)
        shutil.copy2(BIN / 'kiln-example-backend', ack_worker)
        ackport = port()
        reader, writer = os.pipe(); os.close(reader)
        guardian = subprocess.Popen([str(BIN / 'kiln'), 'worker-guardian', str(state), str(ack_worker), '--port', str(ackport)], stdin=subprocess.PIPE, stdout=writer, stderr=log)
        os.close(writer)
        try:
            guardian.wait(timeout=8)
            assert guardian.returncode == 0, 'Guardian did not handle closed acknowledgement pipe safely'
            wait(lambda: closed(ackport) and not workers())
            with open(state / 'workers.lock', 'a') as ownership:
                fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('PASS: closed launch acknowledgement pipe does not orphan worker or retain ownership lock', flush=True)
        finally:
            guardian.stdin.close()
            if guardian.poll() is None:
                guardian.kill(); guardian.wait(timeout=5)
        shutil.rmtree(state / 'releases/ack')
        process = launch(); ready()
        contender = launch()
        contender.wait(timeout=5)
        assert contender.returncode != 0, 'Second supervisor acquired the same state directory'
        assert 'runtime running' in command('status')
        print('PASS: second supervisor rejected without disturbing the running instance', flush=True)
        original_host_key = (state / 'ssh-host-ed25519.pub').read_bytes()
        for name, p in [('rest', restport), ('websocket', wsport), ('stopped', stoppedport)]:
            command(f'app install {manifest(name, "1.0.0", p)}')
            command(f'app start crash/{name}')
            wait(lambda p=p: version(p) == '1.0.0')
        command('app stop crash/stopped')
        command('vault grant crash/rest recovery-test')
        vault_files = {name: hashlib.sha256((state / name).read_bytes()).hexdigest() for name in ['vault.enc', 'vault-config.json']}
        firstport = port()
        client = start_deploy(manifest('managed', '1.0.0', firstport, True))
        readiness_samples = []
        deadline = time.monotonic() + 25
        while client.poll() is None and time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{firstport}/health', timeout=.5) as response:
                    readiness_samples.append(response.status)
            except Exception as error:
                readiness_samples.append(type(error).__name__)
            time.sleep(.05)
        output, error = client.communicate(timeout=5)
        assert client.returncode == 0, ('Initial managed deploy failed', output.decode(), error.decode(), 'Direct candidate /health observations', sorted(set(map(str, readiness_samples))))
        old = workers(); assert len(old) == 3, old
        crash()
        # This represents the persisted task state at the moment of a crash.
        task_id = str(uuid.uuid4())
        (state / 'ai-tasks.json').write_text(json.dumps(dict(concurrency=4, records=[dict(id=task_id, prompt='fixture: interrupted read-only investigation', state='running', output='partial', created=0)])))
        restore(3, old)
        assert version(restport) == version(ingress) == '1.0.0'
        with websocket(wsport) as s:
            assert echo(s)
        assert (state / 'ssh-host-ed25519.pub').read_bytes() == original_host_key
        assert 'recovery-test' in command('vault list')
        assert 'recovery-test' in command('vault grants crash/rest')
        for name, digest in vault_files.items():
            assert hashlib.sha256((state / name).read_bytes()).hexdigest() == digest
        task = command(f'ai task show {task_id}')
        assert '[interrupted]' in task and 'not automatically replayed' in task, task
        assert json.loads((state / 'ai-tasks.json').read_text())['records'][0]['state'] == 'interrupted'
        print('PASS: SIGKILL restores REST/WebSocket/ingress with fresh workers, stopped intent, stable SSH identity and unchanged encrypted Vault/grants', flush=True)
        print('PASS: seeded persisted running task becomes interrupted; no provider configuration or automatic replay', flush=True)

        # Candidate is listening but /missing cannot pass readiness, so durable
        # active manifest is still v1 when we kill the supervisor.
        candidateport = port(); client = start_deploy(manifest('managed', '2.0.0', candidateport, True, '/missing'))
        wait(lambda: version(candidateport) == '2.0.0')
        assert version(ingress) == '1.0.0'
        assert json.loads((state / 'applications.json').read_text())['crash/managed']['manifest']['version'] == '1.0.0'
        old = workers(); assert len(old) == 4, old
        crash(); client.wait(timeout=5); restore(3, old)
        assert version(ingress) == '1.0.0'
        wait(lambda: closed(candidateport))
        assert not (state / 'releases/crash/managed/2.0.0').exists(), 'Interrupted release directory was not reclaimed'
        print('PASS: uncommitted candidate removed after crash; prior active release restored and candidate port released', flush=True)

        # Holding an actual WebSocket pins the old generation during drain.
        held = websocket(ingress); echo(held)
        committedport = port(); client = start_deploy(manifest('managed', '3.0.0', committedport, True))
        wait(lambda: version(ingress) == '3.0.0')
        assert client.poll() is None, 'Deployment should still be draining old connection'
        assert json.loads((state / 'applications.json').read_text())['crash/managed']['manifest']['version'] == '3.0.0'
        echo(held); old = workers(); assert len(old) == 4, old
        crash(); client.wait(timeout=5); held.close(); held = None
        restore(3, old)
        assert version(ingress) == '3.0.0'
        wait(lambda: closed(firstport))
        with websocket(ingress) as s:
            echo(s)
        assert 'Previous: 1.0.0' in command('app releases crash/managed')
        command('app rollback crash/managed'); assert version(ingress) == '1.0.0'
        print('PASS: committed generation restored after crash during drain; old generation gone, new WebSocket works, persisted rollback works', flush=True)
        # A real SIGTERM handler keeps this worker alive during restart teardown,
        # making the vulnerable stop/start interval deterministic without hooks.
        stubborn = tmp / 'restart-worker.py'
        stubborn.write_text('#!' + sys.executable + '\n'
            'import os, pathlib, signal, time\n'
            'root = pathlib.Path(os.environ["KILN_DATA_DIR"])\n'
            'def stopping(signum, frame):\n'
            '    (root / "term-received").write_text(str(os.getpid()))\n'
            'signal.signal(signal.SIGTERM, stopping)\n'
            '(root / "inherited-signal-mask").write_text(",".join(str(int(s)) for s in signal.pthread_sigmask(signal.SIG_BLOCK, set())))\n'
            '(root / "running-pid").write_text(str(os.getpid()))\n'
            'while True: time.sleep(0.05)\n')
        stubborn.chmod(0o700)
        restart_manifest = tmp / 'restart.json'
        restart_manifest.write_text(json.dumps(dict(application='crash', name='restart', version='1.0.0', executable=str(stubborn), arguments=[])))
        command(f'app install {restart_manifest}'); command('app start crash/restart')
        restart_data = state / 'data/crash/restart'
        pid_file = restart_data / 'running-pid'
        wait(pid_file.exists); old_restart_pid = int(pid_file.read_text())
        inherited_mask = (restart_data / 'inherited-signal-mask').read_text().split(',')
        required_signals = [signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGUSR1, signal.SIGUSR2, signal.SIGCHLD]
        assert not {str(int(sig)) for sig in required_signals}.intersection(inherited_mask), ('Worker inherited blocked application signals', inherited_mask)
        wait(lambda: len(workers()) == 4)
        client = subprocess.Popen(base + ['app restart crash/restart'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        clients.append(client)
        wait(lambda: (restart_data / 'term-received').exists())
        assert client.poll() is None, 'Restart already completed before the crash injection'
        assert int((restart_data / 'term-received').read_text()) == old_restart_pid
        assert json.loads((state / 'applications.json').read_text())['crash/restart']['desiredRunning'] is True, 'Restart incorrectly persisted stopped intent'
        old = workers(); assert old_restart_pid in old
        crash(); client.wait(timeout=5); restore(4, old)
        wait(lambda: int(pid_file.read_text()) != old_restart_pid)
        assert json.loads((state / 'applications.json').read_text())['crash/restart']['desiredRunning'] is True
        command('app stop crash/restart'); wait(lambda: len(workers()) == 3)
        print('PASS: SIGKILL during restart teardown preserves running intent and restores a fresh worker', flush=True)
        process.terminate(); process.wait(timeout=15); assert process.returncode == 0
        wait(lambda: not workers())
        print('PASS: clean final shutdown leaves no fixture workers. This test does not reboot the host.', flush=True)
    except Exception:
        log.flush(); print((tmp / 'runtime.log').read_text().replace(secret, '[REDACTED]'), flush=True)
        print('Fixture workers:', workers(), flush=True)
        for diagnostic_client in clients:
            if diagnostic_client.poll() is not None:
                out, err = diagnostic_client.communicate(timeout=2)
                print('Completed fixture command:', diagnostic_client.returncode, out.decode(errors='replace')[-2048:].replace(secret, '[REDACTED]'), err.decode(errors='replace')[-2048:].replace(secret, '[REDACTED]'), flush=True)
        for worker_log in sorted((state / 'logs').rglob('*.log'))[:10]:
            print('Worker log:', worker_log.relative_to(state), flush=True)
            print(worker_log.read_text(errors='replace')[-65536:].replace(secret, '[REDACTED]'), flush=True)
        raise
    finally:
        if held:
            held.close()
        for client in clients:
            if client.poll() is None:
                client.kill()
            client.communicate(timeout=5)
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
        subprocess.run([str(BIN / 'kiln'), 'session-service-stop', '--state', str(state)], capture_output=True, timeout=10)
        for pid in workers():
            # Revalidate ownership immediately before signaling.
            if pid in workers():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        log.close()
