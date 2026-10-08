#!/usr/bin/env python3
"""Named OpenSSH users, scopes, revocation and audit redaction on an isolated node."""
import json, os, pathlib, select, shlex, signal, socket, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT/'.build/debug'))
def wait(fn, seconds=15):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            result=fn()
            if result: return result
        except (OSError, AssertionError): pass
        time.sleep(.1)
    raise AssertionError('Timed out')
with tempfile.TemporaryDirectory(prefix='kiln-identities-') as directory:
    tmp=pathlib.Path(directory); state=tmp/'state'
    with socket.socket() as listener: listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
    for name in ['admin','reader','operator','backup']:
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(tmp/name)],check=True)
    log=open(tmp/'runtime.log','w+')
    process=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(port)],stdout=log,stderr=log)
    live=None
    def args(user):
        return ['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=no','-o',f'UserKnownHostsFile={tmp/"known"}','-o','ConnectTimeout=2','-i',str(tmp/user),'-p',str(port),f'{user}@127.0.0.1']
    def run(command,user='admin',ok=True):
        result=subprocess.run(args(user)+[command],capture_output=True,text=True,timeout=15)
        if ok: assert result.returncode==0,(command,result.stdout,result.stderr)
        else: assert result.returncode!=0,(command,result.stdout)
        return result.stdout
    try:
        wait(lambda: run('status'))
        run(f'identity add reader viewer {shlex.quote(str(tmp/"reader.pub"))} sample/worker')
        run(f'identity add operator operator {shlex.quote(str(tmp/"operator.pub"))} sample/worker')
        assert 'Kiln' in run('status','reader')
        for app in ['sample','other']:
            manifest=tmp/(app+'.json')
            manifest.write_text(json.dumps({'application':app,'name':'worker','version':'1','executable':'/bin/sleep','arguments':['60']}))
            run('app install '+shlex.quote(str(manifest)))
        run('app start sample/worker','operator')
        assert 'sample/worker' in run('app list','reader')
        assert 'other/worker' not in run('app list','reader')
        assert 'Running' in run('app health sample/worker','reader')
        run('app stop sample/worker','operator')
        for command in ['app start sample/worker','app health other/worker','vault list','session list','identity list','ai task list','node list']:
            run(command,'reader',False)
        run('app stop other/worker','operator',False)
        # A non-PTY shell keeps the same authenticated SSH channel across revocation.
        live=subprocess.Popen(args('reader')+['-T'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        live.stdin.write(b'status\n'); live.stdin.flush()
        received=b''
        deadline=time.monotonic()+5
        while b'Release:' not in received and time.monotonic()<deadline:
            if select.select([live.stdout],[],[],.2)[0]: received+=os.read(live.stdout.fileno(),65536)
        assert b'Release:' in received,received
        run('identity revoke reader')
        live.stdin.write(b'status\n'); live.stdin.flush()
        denied=b''; deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if select.select([live.stdout],[],[],.2)[0]:
                chunk=os.read(live.stdout.fileno(),65536)
                if not chunk: break
                denied+=chunk
                if b'Identity revoked' in denied: break
        assert b'Identity revoked' in denied or live.poll() is not None,denied
        run('status','reader',False)
        run('identity revoke admin',ok=False)
        run('ai ask PRIVATE_SENTINEL_SHOULD_NOT_BE_AUDITED',ok=False)
        records=[json.loads(p.read_text()) for p in (state/'audit').rglob('*.json')]
        assert records and any(r['principal']=='reader' and r['outcome']=='denied' for r in records)
        assert not any('PRIVATE_SENTINEL' in json.dumps(r) for r in records)
        assert any(r['outcome']=='returned' and 'requestID' in r for r in records)
        print('PASS named OpenSSH users, role/scope denies, existing-session revocation, last-admin protection, private audit metadata')
    finally:
        if live and live.poll() is None: live.terminate(); live.wait(timeout=5)
        if process.poll() is None: process.terminate(); process.wait(timeout=20)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        log.close()
