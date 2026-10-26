#!/usr/bin/env python3
"""Real Swift IDE acceptance over SSH: SourceKit, compiler diagnostics, wrap and run.
Disposable project and pinned SDK; no provider traffic or user credentials.
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
    (project/'Models').mkdir(); (project/'Models/Jump.swift').write_text('struct JumpTarget { let value = 1 }\n'); (project/'Models/Jump.swift').chmod(0o600)
    source = project/'App.swift'; original = (ROOT/'Sources/ExampleWeb/Web.swift').read_bytes()+b'\nfunc ideDefinitionProbe(_ value: JumpTarget) {}\nfunc ideRenameProbe() { let renameLocal = 1; print(renameLocal) }\nfunc ideFixProbe() { var neverMutated = 1; print(neverMutated) }\n'
    source.write_bytes(original); source.chmod(0o600)
    sdk = root/'sdk.json'
    subprocess.run(['python3',str(ROOT/'scripts/export-web-sdk.py'),'--build-dir',str(BIN),'--output',str(sdk),'--snapshot-dir',str(root/'sdk-inputs')],check=True)
    ports = set()
    while len(ports) < 4: ports.add(freeport())
    sshport, ingress, worker, alternate = sorted(ports)
    origin = f'http://127.0.0.1:{ingress}'
    key = root/'admin'; subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    log = (root/'runtime.log').open('w'); client = None; master = None
    runtime = subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--host','127.0.0.1','--port',str(sshport)],stdin=subprocess.DEVNULL,stdout=log,stderr=log)
    try:
        wait(lambda:(state/'ssh-host-ed25519.pub').exists())
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
        def expect(text,seconds=45):
            print('Checking '+text,flush=True)
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
        send(b'\r'); expect('Codebase / draft/site / workspace'); expect('[Build] [Run] [Def]')
        send(b'\x1b[23~'); expect('Build passed.'); send(b'\x1b'); drain()
        # Explicit completion at the draft caret, from the real Swift language server.
        send(b'e'); expect('[EDITING]')
        send(b'\x1b[200~func completionProbe() { let word = "hello"; word.\x1b[201~')
        send(b'\x00'); expect('Suggestions: Up/Down'); send(b'\x1b'); drain()
        send(b'\x1b'); expect('Discard unsaved edits?'); send(b'\x1b[B\r'); drain(); expect('[R Refactor]')
        # Default is unwrapped; the toolbar toggles visual wrapping without source edits.
        expect('Wrap OFF'); send(b'\x1b[17~'); expect('Wrap ON'); send(b'\x1b[17~'); expect('Wrap OFF')
        # Navigate a symbol's compiler-resolved definition in another project file.
        send(b'\x1b[F'); expect('ideDefinitionProbe')
        def click_word(word):
            drain()
            for row,line in enumerate(screen.display):
                if word in line[:90]:
                    column=line.index(word)+2
                    send(f'\x1b[<0;{column};{row+1}M'.encode()); return
            raise AssertionError((word,frame()))
        cursor=original.decode().index('JumpTarget')+1
        direct=json.loads(ssh('web ide draft/site definition App.swift '+str(cursor)))
        assert direct['locations'][0]['path']=='Models/Jump.swift'
        print('CLI definition verified',flush=True)
        local=original.decode().index('renameLocal')+1
        references=json.loads(ssh('web ide draft/site references App.swift '+str(local)))
        assert len(references['locations'])>=2,references
        proposal=json.loads(ssh('web ide draft/site rename App.swift '+str(local)+' renamedLocal'))
        assert 'renamedLocal' in proposal['renameFiles']['App.swift']['text']
        project_references=json.loads(ssh('web ide draft/site references App.swift '+str(cursor)))
        assert project_references.get('coverage')=='project'
        assert {item['path'] for item in project_references['locations']}=={'App.swift','Models/Jump.swift'}
        project_rename=json.loads(ssh('web ide draft/site rename App.swift '+str(cursor)+' JumpDevice'))
        assert set(project_rename['renameFiles'])=={'App.swift','Models/Jump.swift'}
        assert 'struct JumpDevice' in project_rename['renameFiles']['Models/Jump.swift']['text']
        assert source.read_bytes()==original and json.loads(get('/__kiln/instance'))['instance']==old_instance
        print('CLI semantic references and rename proposal verified; source/release unchanged',flush=True)
        click_word('JumpTarget'); send(b'\x1b[24~'); expect('Swift definitions'); expect('Models/Jump.swift')
        send(b'\r'); expect('struct JumpTarget')
        # Return to App.swift through the tree.
        send(b'\t\x1b[A\r'); expect('actor CounterModel')
        send(b'e'); expect('[EDITING]')
        # Home puts this invalid token at the start of the caret's current line.
        send(b'\x1b[H'); send(b'\x1b[200~NOT_VALID_SWIFT\n\x1b[201~')
        send(b'\x1b[23~'); expect('Build failed.'); expect('error:')
        send(b'\x1b[<0;10;7M'); expect('NOT_VALID_SWIFT')
        send(b'\x1b[14~'); expect('Swift diagnostics'); expect('error:')
        send(b'\r'); expect('NOT_VALID_SWIFT')
        assert source.read_bytes()==original and json.loads(get('/__kiln/instance'))['instance']==old_instance
        send(b'\x1b'); expect('Discard unsaved edits?'); send(b'\x1b[B\r'); drain(); expect('[R Refactor]')
        # Formatting and compiler actions create local drafts through the same
        # independent SSH lane; they never write source or restart the release.
        formatted=json.loads(ssh('web ide draft/site format App.swift 0'))
        assert formatted.get('renameFiles'),formatted
        fix_cursor=original.decode().index('var neverMutated')
        fixes=json.loads(ssh('web ide draft/site codeActions App.swift '+str(fix_cursor)))
        assert any('let neverMutated' in (item.get('files') or {}).get('App.swift',{}).get('text','') for item in fixes.get('codeActions',[])),fixes
        send(b'\x1b[12~'); expect('Formatting proposal')
        send(b'\r'); expect('Formatting applied to drafts')
        send(b'\x1b'); expect('Discard unsaved edits?'); send(b'\x1b[B\r'); drain()
        send(b'\x1b[F'); expect('ideFixProbe')
        click_word('neverMutated'); send(b'\x1b[13~'); expect('Compiler actions:')
        click_word("Replace 'var'"); expect('Compiler action applied to drafts')
        assert source.read_bytes()==original and json.loads(get('/__kiln/instance'))['instance']==old_instance
        send(b'\x1b'); expect('Discard unsaved edits?'); send(b'\x1b[B\r'); drain()
        print('PASS formatting and compiler fix over SSH: both applied only to drafts; source/release unchanged',flush=True)
        # Run restarts the deployed release, not a discarded draft.
        send(b'\x1b[15~'); expect('Started draft/site'); send(b'\r'); expect('Codebase / draft/site')
        assert source.read_bytes()==original and get('/assets/app.css')==css
        assert json.loads(get('/__kiln/instance'))['instance']!=old_instance
        print('PASS real SSH Swift IDE: clean draft build, SourceKit completion, cross-file definition, semantic references, rename proposal without publication, clickable build and live diagnostics, wrap toggle, deployed Run, source/CSS unchanged',flush=True)
        print('KILN_SWIFT_IDE_ACCEPTANCE_COMPLETE',flush=True)
    finally:
        if client is not None and client.poll() is None:client.kill();client.wait(timeout=5)
        if master is not None:os.close(master)
        if runtime.poll() is None:runtime.terminate();runtime.wait(timeout=20)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=15)
        log.close()
