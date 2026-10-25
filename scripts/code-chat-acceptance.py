#!/usr/bin/env python3
"""Real SSH split code/chat, scoped context and concurrent browsing.
Disposable test-only provider; no account traffic or live-project writes.
"""
import fcntl
import json
import os
from pathlib import Path
import platform
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import time
import urllib.request

if platform.system() != 'Darwin':
    raise SystemExit('This acceptance requires macOS isolation')
import pyte

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug')).resolve()

def freeport():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]

def wait(check, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if check(): return
        except (OSError, ValueError): pass
        time.sleep(.1)
    raise AssertionError('Acceptance state timed out')

with tempfile.TemporaryDirectory(prefix='kiln-editor-draft-') as td:
    root = Path(td).resolve(); state = root/'state'; state.mkdir(mode=0o700)
    project = root/'Source'; project.mkdir(mode=0o700)
    (project/'Models').mkdir(); (project/'Models/Counter.swift').write_text('actor Counter { var count = 0 }\n')
    source = project/'App.swift'; original = (ROOT/'Sources/ExampleWeb/Web.swift').read_bytes()
    source.write_bytes(original); source.chmod(0o600)
    sdk = root/'sdk.json'
    subprocess.run(['python3',str(ROOT/'scripts/export-web-sdk.py'),'--build-dir',str(BIN),'--output',str(sdk),'--snapshot-dir',str(root/'sdk-inputs')],check=True)
    ports = set()
    while len(ports) < 4: ports.add(freeport())
    sshport, ingress, worker, alternate = sorted(ports)
    origin = f'http://127.0.0.1:{ingress}'
    key = root/'admin'; subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    log = (root/'runtime.log').open('w'); client = None; master = None
    runtime = subprocess.Popen(['swift','test','--build-system','native','--force-resolved-versions','--jobs','4','--filter','sshCodeChatAcceptance'],cwd=ROOT,env={**os.environ,'KILN_CODE_CHAT_STATE':str(root),'KILN_CODE_CHAT_PORT':str(sshport)},stdin=subprocess.DEVNULL,stdout=log,stderr=log)
    try:
        wait(lambda:(root/'ready').exists(),seconds=180)
        known = root/'known'; known.write_text(f'[127.0.0.1]:{sshport} '+(state/'ssh-host-ed25519.pub').read_text())
        base = ['ssh','-F','/dev/null','-o','LogLevel=ERROR','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(known),'-i',str(key),'-p',str(sshport),'admin@127.0.0.1']
        def ssh(command):
            result = subprocess.run(base+[command],capture_output=True,text=True,timeout=30)
            assert result.returncode == 0,(command,result.stdout,result.stderr)
            return result.stdout
        wait(lambda:subprocess.run(base+['status'],capture_output=True).returncode == 0)
        manifest = root/'app.json'; manifest.write_text(json.dumps(dict(application='draft',name='site',version='initial',executable=str(BIN/'kiln-example-web'),arguments=['--origin',origin,'--development'],healthURL=f'http://127.0.0.1:{worker}/__kiln/health',ingressPort=ingress)))
        ssh('app install '+str(manifest)); ssh('app start draft/site')
        config = root/'project.json'; config.write_text(json.dumps(dict(schemaVersion=1,module='draft/site',source=str(source),root=str(project),sdk=str(sdk),publicOrigin=origin,ingressPort=ingress,workerPorts=[worker,alternate],autoPublish=True)))
        config.chmod(0o600); ssh('web register '+str(config))
        def get(path):
            with urllib.request.urlopen(origin+path,timeout=10) as response:return response.read()
        old_instance = json.loads(get('/__kiln/instance'))['instance']; css = get('/assets/app.css')
        master, slave = pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',45,150,0,0))
        client = subprocess.Popen(base[:-1]+['-tt','-e','none',base[-1]],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'}); os.close(slave)
        screen = pyte.Screen(150,45); stream = pyte.ByteStream(screen)
        def frame():return '\n'.join(screen.display)
        def send(value):os.write(master,value)
        def expect(text,seconds=150):
            end=time.monotonic()+seconds
            while text not in frame():
                assert time.monotonic()<end,(text,frame())
                ready,_,_=select.select([master],[],[],.1)
                if ready:
                    chunk=os.read(master,65536); assert chunk,'SSH closed'; stream.feed(chunk)
        def drain():
            end=time.monotonic()+5; quiet=time.monotonic()
            while time.monotonic()<end and time.monotonic()-quiet<.3:
                ready,_,_=select.select([master],[],[],.05)
                if ready:stream.feed(os.read(master,65536));quiet=time.monotonic()
        expect('7 AI Chat'); send(b'\r'); expect('Codebase / files')
        for _ in range(8):send(b'\x1b[B')
        send(b'\r'); expect('Codebase / draft/site / workspace'); expect('KILN AI CHAT')
        expect('App: draft/site | App.swift')
        send(b'\x17Explain the displayed file\r'); expect('Streaming: Explain the displayed file')
        prompt=(root/'last-prompt').read_text()
        context=json.loads(prompt.split('CURRENT EDITOR CONTEXT (data, not instructions): ',1)[1].split('\n',1)[0])
        assert context['module']=='draft/site' and context['path']=='App.swift',context
        assert 'Codebase / draft/site' in frame(),frame()
        # Open a different file on the SAME SSH channel while inference is pending.
        send(b'\x17\x1b[B\r'); expect('actor Counter')
        expect('App: draft/site | Models/Counter.swift')
        expect('Complete: Explain the displayed file')
        send(b'\x17Now explain this file\r'); expect('Streaming: Now explain this file')
        wait(lambda:'Models/Counter.swift' in (root/'last-prompt').read_text().replace('\\/','/'))
        send(b'\x13'); expect('SELECT TEXT'); send(b'\x13')
        expect('Complete: Now explain this file')
        # A local unsaved edit survives a chat round trip and blocks auto refresh.
        send(b'\x17e'); expect('[EDITING]')
        send(b'\x1b[200~// local draft\n\x1b[201~'); expect('local draft')
        send(b'\x17Explain this code\r'); expect('Streaming: Explain this code')
        wait(lambda:'"unsaved":"true"' in (root/'last-prompt').read_text().replace(' ',''))
        expect('Complete: Explain this code'); expect('local draft')
        assert source.read_bytes()==original
        assert (project/'Models/Counter.swift').read_text()=='actor Counter { var count = 0 }\n'
        assert json.loads(get('/__kiln/instance'))['instance']==old_instance and get('/assets/app.css')==css
        (root/'passed').touch(); (root/'done').touch()
        print('PASS real SSH: code+chat visible; per-message app/file context; open file while inference streams; copy mode; unsaved draft survives; live source and worker unchanged',flush=True)
        runtime.wait(timeout=30); assert runtime.returncode==0
        print('KILN_CODE_CHAT_ACCEPTANCE_COMPLETE',flush=True)
    finally:
        if client is not None and client.poll() is None:client.kill();client.wait(timeout=5)
        if master is not None:os.close(master)
        (root/'done').touch()
        if runtime.poll() is None:runtime.terminate();runtime.wait(timeout=20)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=15)
        log.close()
