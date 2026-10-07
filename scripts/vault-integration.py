#!/usr/bin/env python3
"""Real SSH hidden entry + module delivery. Uses temporary test credentials only."""
import fcntl, hashlib, json, os, pathlib, pty, select, socket, struct, subprocess, sys, tempfile, termios, time, uuid
import pyte
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
def wait(fn, seconds=10):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            result=fn()
            if result: return result
        except Exception: pass
        time.sleep(.05)
    raise AssertionError('Timed out')
with tempfile.TemporaryDirectory(prefix='kiln-vault-integration-') as directory:
    root=pathlib.Path(directory); state=root/'state'; key=root/'ssh-key'
    with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    subprocess.run([str(BIN/'kiln'),'vault','init','--state',str(state),'--key-file',str(root/'vault-master')],check=True,capture_output=True)
    secret='test-only-'+uuid.uuid4().hex
    imported=subprocess.run([str(BIN/'kiln'),'vault','put','unrequested','--state',str(state)],input='different-test-secret',text=True,capture_output=True)
    assert imported.returncode==0
    log=open(root/'runtime.log','w+')
    server=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--port',str(port)],stdout=log,stderr=log)
    client=None; master=None
    try:
        hostkey=state/'ssh-host-ed25519.pub'; wait(hostkey.exists)
        known=root/'known'; known.write_text(f'[127.0.0.1]:{port} '+hostkey.read_text())
        base=['ssh','-F','/dev/null','-e','none','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}','-i',str(key),'-p',str(port)]
        def command(text,ok=True):
            result=subprocess.run(base+['admin@127.0.0.1',text],capture_output=True,text=True,timeout=15)
            if ok: assert result.returncode==0,(text,result.stdout,result.stderr)
            assert secret not in result.stdout+result.stderr
            return result
        wait(lambda: command('status').returncode==0)
        master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,110,0,0))
        client=subprocess.Popen(base+['-tt','admin@127.0.0.1'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'})
        os.close(slave); screen=pyte.Screen(110,30); stream=pyte.ByteStream(screen); raw=bytearray()
        def pump(duration=.2):
            end=time.monotonic()+duration
            while time.monotonic()<end:
                ready,_,_=select.select([master],[],[],max(0,end-time.monotonic()))
                if ready:
                    data=os.read(master,65536);raw.extend(data);stream.feed(data)
        def expect(text):
            end=time.monotonic()+8
            while text not in '\n'.join(screen.display):
                pump(.1); assert time.monotonic()<end,(text,'\n'.join(screen.display))
        def send(data): os.write(master,data);pump()
        expect('Overview');send(b'`');send(b'vault put mail-token\r');expect('KILN VAULT')
        send(b'\x1b[200~'+secret.encode()+b'\x1b[201~');pump(1.2)
        assert secret.encode() not in raw
        send(b'\r');expect('Stored mail-token')
        send(b'vault put cancelled\r');expect('KILN VAULT');send(b'not-saved');send(b'\x1b');pump(.4);expect('cancelled')
        assert 'cancelled' not in command('vault list').stdout
        command('vault grant demo/worker unrequested')
        worker=root/'worker.py'
        worker.write_text('#!'+sys.executable+'\nimport hashlib,json,os,time\nfrom pathlib import Path\nPath(os.environ["KILN_DATA_DIR"],"proof.json").write_text(json.dumps({"digest":hashlib.sha256(os.environ["MAIL_TOKEN"].encode()).hexdigest(),"extra":"UNREQUESTED" in os.environ}))\ntime.sleep(60)\n')
        worker.chmod(0o700)
        manifest=root/'module.json';manifest.write_text(json.dumps(dict(application='demo',name='worker',version='26.10.07.2',executable=str(worker),arguments=[],secrets={'MAIL_TOKEN':'mail-token'})))
        command(f'app install {manifest}')
        assert command('app start demo/worker',False).returncode==1
        command('vault grant demo/worker mail-token');command('app start demo/worker')
        proof=state/'data/demo/worker/proof.json'; wait(proof.exists)
        data=json.loads(proof.read_text());assert data['digest']==hashlib.sha256(secret.encode()).hexdigest();assert not data['extra']
        command('vault revoke demo/worker mail-token');command('app stop demo/worker')
        assert command('app start demo/worker',False).returncode==1
        for file in state.rglob('*'):
            if file.is_file(): assert secret.encode() not in file.read_bytes(),file.name
        assert secret.encode() not in raw and b'not-saved' not in raw
        print('PASS: SSH hidden input/paste/cancel; secret absent from terminal output and state/log files',flush=True)
        print('PASS: module denied before grant; receives requested secret only; future start denied after revoke',flush=True)
        client.kill();client.wait(timeout=5);client=None
        server.terminate();server.wait(timeout=12)
        reopened=subprocess.run([str(BIN/'kiln'),'vault','put','mail-token','--state',str(state)],input='rotated-test-only',text=True,capture_output=True)
        assert reopened.returncode==0
        print('PASS: headless stdin import and encrypted store reopen after runtime shutdown',flush=True)
    finally:
        if client and client.poll() is None: client.kill();client.wait(timeout=5)
        if master is not None: os.close(master)
        if server.poll() is None: server.terminate();server.wait(timeout=12)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
        log.close()
