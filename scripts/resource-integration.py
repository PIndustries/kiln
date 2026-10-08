#!/usr/bin/env python3
"""Actual cgroup-v2 enforcement in a disposable Linux/systemd VM, run as root.
The Kiln service itself runs unprivileged. No mounts or host reboots are performed.
KILN_BIN_DIR points to installed, executable Linux binaries.
"""
import json
import os
import pathlib
import pwd
import re
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', '/opt/kiln-test/bin')).resolve()
assert os.geteuid() == 0 and pathlib.Path('/run/systemd/system').is_dir(), 'Run in disposable Linux/systemd VM as root'
unit = f'kiln-resource-proof-{os.getpid()}'
created_user = False
try:
    account = pwd.getpwnam('kiln')
except KeyError:
    subprocess.run(['useradd', '--system', '--no-create-home', '--shell', '/usr/sbin/nologin', 'kiln-resource-proof'], check=True)
    account = pwd.getpwnam('kiln-resource-proof'); created_user = True


def available_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]


def wait(fn, seconds=20):
    end = time.monotonic() + seconds; error = None
    while time.monotonic() < end:
        try:
            result = fn()
            if result: return result
        except Exception as exc: error = exc
        time.sleep(.1)
    raise AssertionError(f'Timed out: {error}')


with tempfile.TemporaryDirectory(prefix='kiln-resources-', dir='/var/tmp') as temporary:
    root = pathlib.Path(temporary)
    os.chown(root, account.pw_uid, account.pw_gid)
    state = root / 'state'; key = root / 'admin'; known = root / 'known'
    sshport, peerport = available_port(), available_port()
    while peerport == sshport: peerport = available_port()
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    ssh = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=2', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}', '-i', str(key), '-p', str(sshport), 'admin@127.0.0.1']

    def command(value):
        result = subprocess.run(ssh + [value], capture_output=True, text=True, timeout=25)
        assert result.returncode == 0, (value, result.stdout, result.stderr)
        return result.stdout

    def health():
        with urllib.request.urlopen(f'http://127.0.0.1:{peerport}/health', timeout=2) as response:
            return response.status == 200

    def install(name, source, memory=134217728, cpu=250, pids=32):
        script = root / f'{name}.py'
        script.write_text('#!/usr/bin/python3\n' + source); script.chmod(0o755)
        manifest = dict(application='resource', name=name, version='1', executable=str(script), arguments=[], resources=dict(memoryBytes=memory, cpuMillis=cpu, maxProcesses=pids))
        path = root / f'{name}.json'; path.write_text(json.dumps(manifest))
        command(f'app install {path}'); command(f'app start resource/{name}')

    def group(name):
        output = command(f'app resources resource/{name}')
        matched = re.search(r'^Cgroup: (.+)$', output, re.M)
        assert matched, output
        path = pathlib.Path(matched[1])
        assert f'/{unit}.service/kiln-workers/kiln-' in str(path), path
        return path

    def counters(path, name):
        return dict(line.split() for line in (path / name).read_text().splitlines())

    try:
        subprocess.run(['systemd-run', '--quiet', f'--unit={unit}', f'--uid={account.pw_name}', f'--gid={account.pw_gid}', '--property=Delegate=cpu memory pids', '--property=KillMode=control-group', '--property=RuntimeMaxSec=240', '--property=MemoryMax=768M', '--property=TasksMax=192', '--property=CPUQuota=100%', '--property=NoNewPrivileges=yes', '--setenv=KILN_CGROUP_ROOT=auto', str(BIN / 'kiln'), 'up', '--state', str(state), '--authorized-keys', str(key) + '.pub', '--port', str(sshport)], check=True)
        host = state / 'ssh-host-ed25519.pub'; wait(host.exists)
        known.write_text(f'[127.0.0.1]:{sshport} ' + host.read_text())
        wait(lambda: 'runtime running' in command('status'))
        mainpid = int(subprocess.check_output(['systemctl', 'show', unit, '--property=MainPID', '--value'], text=True))
        assert pathlib.Path(f'/proc/{mainpid}').stat().st_uid == account.pw_uid != 0, 'Runtime must enforce via delegated non-root account'

        install('peer', f'''from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')
 def log_message(self,*args): pass
HTTPServer(('127.0.0.1',{peerport}),Handler).serve_forever()
''')
        wait(health)
        peer = group('peer'); assert (peer / 'memory.max').read_text().strip() == '134217728'
        index = json.loads((state / 'applications.json').read_text())
        assert index['formatVersion'] == 2 and 'resource/peer' in index['applications'], 'Resource state must reject old dictionary-only runtimes'
        print('PASS unprivileged systemd delegation and pre-exec application cgroup attachment', flush=True)

        install('cpu', 'while True: pass\n', cpu=125)
        cpu_group = group('cpu')
        assert (cpu_group / 'cpu.max').read_text().strip() == '12500 100000'
        wait(lambda: int(counters(cpu_group, 'cpu.stat')['nr_throttled']) > 0)
        assert health(); command('app stop resource/cpu'); wait(lambda: not cpu_group.exists())
        print('PASS CPU bandwidth is kernel-throttled; peer remains healthy', flush=True)

        install('pids', '''import os, signal, time, json
from pathlib import Path
children=[]
while True:
 try: child=os.fork()
 except OSError: break
 if child == 0:
  os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN)
  while True: time.sleep(1)
 children.append(child)
Path(os.environ['KILN_DATA_DIR'],'children.json').write_text(json.dumps(children))
while True: time.sleep(1)
''', pids=16)
        child_file = state / 'data/resource/pids/children.json'; wait(child_file.exists)
        pids_group = group('pids'); children = json.loads(child_file.read_text())
        assert children and int((pids_group / 'pids.current').read_text()) <= 16
        assert int(counters(pids_group, 'pids.events')['max']) > 0
        assert health()
        # Diagnostic persistence must never gate actual cgroup cleanup. Obstruct
        # mkdir with a regular file, then restore reports for the OOM proof.
        reports = state / 'resource-reports'; saved_reports = state / 'saved-resource-reports'
        if reports.exists(): reports.rename(saved_reports)
        reports.write_text('diagnostic path deliberately obstructed')
        try:
            command('app stop resource/pids'); wait(lambda: not pids_group.exists())
            assert not (state / 'resource-ledger' / (pids_group.name.removeprefix('kiln-') + '.json')).exists()
            assert health()
        finally:
            reports.unlink()
            if saved_reports.exists(): saved_reports.rename(reports)
        print('PASS blocked diagnostic storage does not strand cgroups or ownership', flush=True)
        def terminated(pid):
            path = pathlib.Path(f'/proc/{pid}/stat')
            return not path.exists() or path.read_text().split(') ', 1)[1].startswith('Z ')
        wait(lambda: all(terminated(pid) for pid in children))
        print('PASS fork quota enforced and daemonized descendants killed on stop', flush=True)

        install('oom', "blocks=[]\nwhile True: blocks.append(bytearray(b'x'*1048576))\n", memory=67108864)
        outcome = wait(lambda: (text if 'Enforcement: Linux cgroup v2 (exited)' in text and re.search(r'oom_kill [1-9]', text) else None) if (text := command('app resources resource/oom')) else None)
        assert 'memory.max: 67108864' in outcome
        assert health() and pathlib.Path(f'/proc/{mainpid}').exists()
        print('PASS memory OOM stays inside worker group; supervisor and peer survive', flush=True)

        # Kill only the guardian of this exact fixture generation. Its worker and
        # descendants remain for the runtime's ownership-ledger reconciliation.
        child_file.unlink()
        command('app start resource/pids'); wait(child_file.exists)
        old_group = group('pids'); old_children = json.loads(child_file.read_text())
        rows = [line.split() for line in command('app list').splitlines()]
        worker = int(next(row[4] for row in rows if len(row) == 5 and row[:2] == ['resource', 'pids']))
        guardian = int(next(line.split()[1] for line in pathlib.Path(f'/proc/{worker}/status').read_text().splitlines() if line.startswith('PPid:')))
        guardian_args = pathlib.Path(f'/proc/{guardian}/cmdline').read_bytes().split(b'\0')
        assert b'worker-guardian' in guardian_args and str(state).encode() in guardian_args
        os.kill(guardian, signal.SIGKILL)
        wait(lambda: any(len(row) == 5 and row[:2] == ['resource', 'pids'] and row[3] == 'exited' for row in (line.split() for line in command('app list').splitlines())))
        command('app start resource/pids')
        new_group = group('pids'); assert new_group != old_group and not old_group.exists()
        wait(lambda: all(terminated(pid) for pid in old_children))
        assert health()
        print('PASS guardian-loss reconciliation kills only owned old generation and restores a fresh group', flush=True)

        command('app stop resource/oom')
        active_groups = [group('peer'), group('pids')]
        old_records = {file.name for file in (state / 'resource-ledger').glob('*.json')}
        assert len(old_records) == 2, old_records
        # systemd may report an auxiliary-process race after it already killed
        # this delegated unit. Reconcile the observed outcome; never resend kill.
        kill_result = subprocess.run(['systemctl', 'kill', '--kill-whom=all', '--signal=SIGKILL', unit], capture_output=True, text=True)
        wait(lambda: not pathlib.Path(f'/proc/{mainpid}').exists())
        wait(lambda: all(not path.exists() for path in active_groups))
        assert old_records.issubset({file.name for file in (state / 'resource-ledger').glob('*.json')}), 'Crash fixture must retain ownership ledger'
        subprocess.run(['systemctl', 'restart', unit], check=True)
        wait(lambda: 'runtime running' in command('status'))
        wait(health)
        restored_groups = [group('peer'), group('pids')]
        assert all(path not in active_groups for path in restored_groups)
        assert all((path / 'memory.max').read_text().strip() == '134217728' for path in restored_groups)
        assert old_records.isdisjoint({file.name for file in (state / 'resource-ledger').glob('*.json')})
        rows = [line.split() for line in command('app list').splitlines()]
        assert next(row[3] for row in rows if len(row) == 5 and row[:2] == ['resource', 'oom']) == 'stopped'
        print('PASS service crash removes kernel groups; persisted intent restores fresh enforced generations and honors stopped state', flush=True)

        command('app stop resource/pids'); command('app stop resource/peer')
        print('ALL RESOURCE INTEGRATION CHECKS PASSED', flush=True)
    except Exception:
        logs = subprocess.run(['journalctl', '-u', unit, '--no-pager', '-n', '60'], text=True, capture_output=True)
        print(logs.stdout)
        raise
    finally:
        subprocess.run(['systemctl', 'stop', unit], capture_output=True)
        subprocess.run(['systemctl', 'reset-failed', unit], capture_output=True)
        if created_user: subprocess.run(['userdel', account.pw_name], capture_output=True)
