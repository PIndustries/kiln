#!/usr/bin/env python3
"""Real ProxyJump + native managed SSH. Creates/deletes one temporary macOS Keychain item."""
import json, pathlib, socket, subprocess, tempfile, time, os
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='kiln-bastion-test-') as tmp:
    tmp=pathlib.Path(tmp);jump_port=port();target_port=port();key=tmp/'client'
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    cfg=tmp/'ssh_config';known=tmp/'known_hosts';known.write_text('')
    cfg.write_text(f'''Host kiln
  HostName 127.0.0.1
  Port {jump_port}
  User admin
Host target
  HostName 127.0.0.1
  Port {target_port}
  User admin
  ProxyJump kiln
Host *
  IdentityFile {key}
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile {known}
  ConnectTimeout 3
''')
    processes=[];log=open(tmp/'runtime.log','w');created=False
    def start(name,p,authorized):
        state=tmp/name
        process=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(authorized),'--port',str(p)],stdout=log,stderr=log)
        processes.append(process)
        deadline=time.monotonic()+8
        while not (state/'ssh-host-ed25519.pub').exists():
            assert process.poll() is None,(tmp/'runtime.log').read_text()
            assert time.monotonic()<deadline;time.sleep(.1)
        with known.open('a') as f:f.write(f'[127.0.0.1]:{p} '+(state/'ssh-host-ed25519.pub').read_text())
        time.sleep(.2);return process
    def ssh(host,command,check=True):
        r=subprocess.run(['ssh','-F',str(cfg),host,command],capture_output=True,text=True,timeout=25)
        if check:assert r.returncode==0,(r.stdout,r.stderr)
        return r
    jump=None;target=None
    try:
        jump=start('jump',jump_port,str(key)+'.pub')
        ssh('kiln','key create fixture');created=True
        public=ssh('kiln','key public fixture').stdout.strip()
        authorized=tmp/'authorized';authorized.write_text((tmp/'client.pub').read_text()+public+'\n')
        target=start('target',target_port,authorized)
        denied=ssh('target','status',False)
        assert denied.returncode!=0,'Unregistered destination accepted'
        ssh('kiln',f'server add fixture 127.0.0.1 admin {target_port}')
        assert 'runtime running' in ssh('target','status').stdout
        print('PASS: real OpenSSH ProxyJump; unregistered destination denied',flush=True)
        ssh('kiln','server key fixture fixture')
        no_pin=ssh('kiln',"server exec fixture 'status'",False)
        assert no_pin.returncode!=0
        scan=ssh('kiln','server scan fixture').stdout
        trusted=subprocess.check_output(['ssh-keygen','-lf',str(tmp/'target/ssh-host-ed25519.pub')],text=True).split()[1]
        assert trusted in scan
        assert ssh('kiln','server trust fixture SHA256:not-the-key',False).returncode!=0
        ssh('kiln',f'server trust fixture {trusted}')
        result=ssh('kiln',"server exec fixture 'status'")
        assert 'runtime running' in result.stdout,result.stdout
        print('PASS: Keychain-generated key authenticates native SSH; host pin required',flush=True)
        ssh('kiln',f'server add rejected 127.0.0.1 nobody {target_port}')
        ssh('kiln','server key rejected fixture')
        ssh('kiln','server scan rejected')
        ssh('kiln',f'server trust rejected {trusted}')
        assert ssh('kiln',"server exec rejected 'status'",False).returncode!=0
        assert 'runtime running' in ssh('kiln','status').stdout
        ssh('kiln','server remove rejected')
        print('PASS: rejected destination authentication leaves runtime available',flush=True)
        data=json.loads((tmp/'jump/bastion.json').read_text())
        assert set(data['keys']['fixture'])=={'publicKey'}
        jump.terminate();jump.wait(timeout=12)
        jump=start('jump',jump_port,str(key)+'.pub')
        assert 'runtime running' in ssh('kiln',"server exec fixture 'status'").stdout
        print('PASS: server profiles and Keychain credential survive runtime restart',flush=True)
        target.terminate();target.wait(timeout=12)
        (tmp/'target/ssh-host-ed25519').unlink();(tmp/'target/ssh-host-ed25519.pub').unlink()
        target=start('target',target_port,authorized)
        mismatch=ssh('kiln',"server exec fixture 'status'",False)
        assert mismatch.returncode!=0 and 'mismatch' in mismatch.stdout.lower(),mismatch.stdout
        print('PASS: changed destination host key rejected',flush=True)
        ssh('kiln','server remove fixture');ssh('kiln','key delete fixture');created=False
        assert ssh('target','status',False).returncode!=0
        print('PASS: removal blocks new tunnels; temporary Keychain item deleted',flush=True)
    except BaseException:
        log.flush()
        print((tmp/'runtime.log').read_text(), flush=True)
        raise
    finally:
        if created and jump and jump.poll() is not None:
            jump=start('jump',jump_port,str(key)+'.pub')
        if created and jump and jump.poll() is None:
            ssh('kiln','server remove rejected',False)
            ssh('kiln','server remove fixture',False)
            cleanup=ssh('kiln','key delete fixture',False)
            if cleanup.returncode: print('Keychain cleanup requires attention: '+cleanup.stdout)
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=12)
                except subprocess.TimeoutExpired:process.kill();process.wait()
        log.close()
