#!/usr/bin/env python3
"""Real OpenSSH multiple-identity and stalled-agent admission checks; isolated node."""
import base64, os, pathlib, socket, struct, subprocess, tempfile, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('KILN_BIN_DIR', ROOT/'.build/debug'))
def wait(fn, seconds=10):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if fn(): return
        time.sleep(.1)
    raise AssertionError('Timed out')
with tempfile.TemporaryDirectory(prefix='kiln-ssh-auth-') as directory:
    tmp=pathlib.Path(directory)
    for name in ['admin']+[f'bad{i}' for i in range(7)]:
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(tmp/name)],check=True)
    with socket.socket() as listener: listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
    log=open(tmp/'runtime.log','w+')
    process=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(port)],stdout=log,stderr=log)
    base=['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','StrictHostKeyChecking=no','-o',f'UserKnownHostsFile={tmp/"known"}','-o','ConnectTimeout=3','-p',str(port)]
    def run(keys, prefix=None, timeout=8):
        args=list(prefix or base)
        for key in keys: args+=['-i',str(tmp/key)]
        return subprocess.run(args+['admin@127.0.0.1','status'],capture_output=True,timeout=timeout)
    agent=None; stop=threading.Event(); signed=threading.Event()
    try:
        wait(lambda: run(['admin']).returncode==0)
        assert run(['bad0','bad1','admin']).returncode==0, 'Few preceding identities must work'
        process.terminate(); process.wait(timeout=20)
        process=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(port)],stdout=log,stderr=log)
        wait(lambda: run(['admin']).returncode==0)
        assert run([f'bad{i}' for i in range(7)]+['admin']).returncode!=0, 'Exhausted budget must fail'
        # New limiter window is unnecessary: above emits <=8 diagnostics. Restart
        # isolated node so stalled-agent reason cannot be hidden by prior failures.
        process.terminate(); process.wait(timeout=20)
        process=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(port)],stdout=log,stderr=log)
        wait(lambda: run(['admin']).returncode==0)
        agent=socket.socket(socket.AF_UNIX); agent.bind(str(tmp/'agent')); agent.listen(1); agent.settimeout(.2)
        key=base64.b64decode((tmp/'admin.pub').read_text().split()[1])
        def string(value): return struct.pack('>I',len(value))+value
        def serve():
            while not stop.is_set():
                try: conn,_=agent.accept(); break
                except socket.timeout: continue
            else: return
            with conn:
                conn.settimeout(.2); data=b''
                while not stop.is_set():
                    try: chunk=conn.recv(65536)
                    except socket.timeout: continue
                    if not chunk: return
                    data+=chunk
                    while len(data)>=4 and len(data)>=4+struct.unpack('>I',data[:4])[0]:
                        size=struct.unpack('>I',data[:4])[0]; message=data[4:4+size]; data=data[4+size:]
                        if message[0]==11:
                            response=b'\x0c'+struct.pack('>I',1)+string(key)+string(b'fixture')
                            conn.sendall(string(response))
                        elif message[0]==13:
                            signed.set()  # Deliberately never answer the signing request.
                        else: conn.sendall(string(b'\x05'))
        thread=threading.Thread(target=serve,daemon=True); thread.start()
        prefix=base.copy(); prefix[prefix.index('IdentityAgent=none')]=f'IdentityAgent={tmp/"agent"}'
        started=time.monotonic(); client=subprocess.Popen(prefix+['-i',str(tmp/'admin.pub'),'admin@127.0.0.1','status'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert signed.wait(5), 'OpenSSH never requested agent signature'
            wait(lambda: 'reason=authentication_timeout' in (tmp/'runtime.log').read_text(),seconds=18)
            assert time.monotonic()-started<22
            assert run(['admin']).returncode==0, 'Stalled agent must not block healthy clients'
        finally:
            client.kill(); client.communicate(timeout=5)
        logs=(tmp/'runtime.log').read_text()
        assert 'reason=authentication_budget' in logs
        assert 'reason=authentication_timeout' in logs
        for name in ['admin']+[f'bad{i}' for i in range(7)]:
            assert (tmp/(name+'.pub')).read_text().split()[1] not in logs
        print('PASS OpenSSH preceding identities, exhausted budget, explicit-key recovery, stalled signing agent deadline, healthy concurrent login, no key leakage')
    finally:
        stop.set()
        if agent: agent.close()
        if process.poll() is None: process.terminate(); process.wait(timeout=20)
        log.close()
