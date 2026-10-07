#!/usr/bin/env python3
"""Real OpenSSH destination + persistent native terminals. Requires pyte and macOS Keychain."""
import fcntl, getpass, os, pathlib, pty, select, signal, socket, struct, subprocess, tempfile, termios, time
import pyte
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
def preview(screen,name):
    directory=os.environ.get('KILN_SESSION_PREVIEW')
    if not directory:return
    from PIL import Image,ImageDraw,ImageFont
    image=Image.new('RGB',(screen.columns*10,screen.lines*22),'#1c1c1c');draw=ImageDraw.Draw(image)
    font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',15)
    def color(value,default):return default if value=='default' else '#'+value if len(value)==6 else value
    for y in range(screen.lines):
        for x in range(screen.columns):
            cell=screen.buffer[y][x]
            draw.rectangle((x*10,y*22,x*10+10,y*22+22),fill=color(cell.bg,'#1c1c1c'))
            draw.text((x*10,y*22),cell.data,font=font,fill=color(cell.fg,'#dddddd'),anchor='la')
    directory=pathlib.Path(directory);directory.mkdir(parents=True,exist_ok=True);image.save(directory/(name+'.png'))
def port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='kiln-sessions-') as tmp:
    tmp=pathlib.Path(tmp); jumpport=port(); remoteport=port(); clients=[]; keycreated=False; destination=None
    for name in ['admin','host']:
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(tmp/name)],check=True)
    log=open(tmp/'runtime.log','w'); sshlog=open(tmp/'sshd.log','w')
    runtime=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(jumpport)],stdout=log,stderr=log)
    base=['ssh','-F','/dev/null','-e','none','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={tmp}/known','-i',str(tmp/'admin'),'-p',str(jumpport)]
    def command(text,check=True):
        r=subprocess.run(base+['admin@127.0.0.1',text],capture_output=True,text=True,timeout=25)
        if check: assert r.returncode==0,(text,r.stdout,r.stderr)
        return r
    def connect():
        master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0))
        child=subprocess.Popen(base+['-tt','admin@127.0.0.1'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'})
        os.close(slave);clients.append((child,master));return child,master,pyte.Screen(100,30)
    def pump(seconds=.2):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            ready,_,_=select.select([master],[],[],max(0,end-time.monotonic()))
            if ready:
                try:data=os.read(master,65536)
                except OSError:break
                if not data:break
                stream.feed(data)
    def expect(text,seconds=6):
        end=time.monotonic()+seconds
        while text not in '\n'.join(screen.display):
            pump(.1)
            assert time.monotonic()<end,(text,'\n'.join(screen.display))
    def send(data):os.write(master,data);pump()
    def click(text):
        for y,line in enumerate(screen.display):
            x=line.find(text)
            if x>=0:
                send(f'\x1b[<0;{x+2};{y+1}M\x1b[<0;{x+2};{y+1}m'.encode());return
        raise AssertionError(('Missing click target',text,'\n'.join(screen.display)))
    def attach(name):send(b'`');expect('COMMAND DRAWER');send(f'session attach {name}\r'.encode());expect(f'1:{name} |')
    try:
        deadline=time.monotonic()+10
        while not (tmp/'state/ssh-host-ed25519.pub').exists():
            assert runtime.poll() is None and time.monotonic()<deadline;time.sleep(.1)
        (tmp/'known').write_text(f'[127.0.0.1]:{jumpport} '+(tmp/'state/ssh-host-ed25519.pub').read_text())
        while command('status',False).returncode:assert time.monotonic()<deadline;time.sleep(.1)
        child,master,screen=connect();stream=pyte.ByteStream(screen);expect('6 Servers')
        send(b'6n');expect('Add server')
        send(f'fixture\r127.0.0.1\r{getpass.getuser()}\r'.encode());send(b'\x15'+str(remoteport).encode()+b'\r')
        expect('Added fixture');send(b'\r');expect('Generate and assign key');click('Generate and assign key')
        send(b'fixture\r');expect('Created fixture');keycreated=True
        (tmp/'authorized').write_text(command('key public fixture').stdout)
        send(b'\x1b');pump(.3)

        (tmp/'sshd.conf').write_text(f'Port {remoteport}\nListenAddress 127.0.0.1\nHostKey {tmp}/host\nPidFile {tmp}/pid\nAuthorizedKeysFile {tmp}/authorized\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nForceCommand /bin/sh -i\n')
        destination=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(tmp/'sshd.conf')],stdout=sshlog,stderr=sshlog)
        time.sleep(.3)
        send(b'\r');click('Scan host key');expect('UNVERIFIED host key')
        fingerprint=subprocess.check_output(['ssh-keygen','-lf',str(tmp/'host.pub')],text=True).split()[1]
        expect(fingerprint)
        send(b'\x1b');pump(.3);send(b'\r');click('Verify host key');expect('Verified SHA256')
        send(fingerprint.encode()+b'\r');expect('Pinned host identity')
        send(b'\r');click('New terminal');expect('Session name');send(b'alpha\r');expect('1:alpha |')
        send(b'\x02d');expect('TERMINAL SESSIONS');send(b'n');expect('choose server');click('fixture')
        send(b'beta\r');expect('1:beta |');send(b'\x02p');expect('1:alpha |')
        print('PASS: menu-only server creation, generated Keychain key, verified host pin and two terminals',flush=True)
        send(b"export KILN_SESSION_TOKEN=retained-alpha; printf 'ALPHA_READY\\n'\r");expect('ALPHA_READY')
        send(b'\x02%');expect('2:beta |')
        # Each side must display independent terminal contents, and clicking focuses input.
        send(b"printf 'SPLIT_%s\\n' RIGHT\r");expect('SPLIT_RIGHT')
        send(b'\x1b[<0;2;2M\x1b[<0;2;2m');expect('1:alpha |')
        send(b'printf "LEFT_TOKEN=%s\\n" "$KILN_SESSION_TOKEN"\r');expect('LEFT_TOKEN=retained-alpha')
        preview(screen,'side-by-side')
        send(b'\x02"');pump(.4)
        send(b'stty size\r');expect('13 100')
        send(b'\x02o');send(b"printf 'STACKED_%s\\n' BETA\r");expect('STACKED_BETA')
        preview(screen,'stacked')
        send(b'\x02l');pump(.4);send(b'\x02x');expect('1:beta |')
        print('PASS: side-by-side and stacked panes, mouse/keyboard focus, resizing and unsplit',flush=True)

        send(b"printf 'BETA_READY\\n'\r");expect('BETA_READY')
        send(b'\x02p');expect('1:alpha |');expect('ALPHA_READY')
        print('PASS: two real remote PTYs; switching restores independent terminal screens',flush=True)
        send(b"(sleep 2; printf 'BACKGROUND_%s\\n' FINISHED) &\r")
        child.kill();child.wait(timeout=5)
        time.sleep(2.5)
        assert 'alpha  fixture  running  detached' in command('session list').stdout
        child,master,screen=connect();stream=pyte.ByteStream(screen);expect('5 Sessions');attach('alpha')
        expect('BACKGROUND_FINISHED')
        send(b'printf "TOKEN=%s\\n" "$KILN_SESSION_TOKEN"\r');expect('TOKEN=retained-alpha')
        print('PASS: abrupt viewer disconnect preserves shell environment and background output',flush=True)
        send(b"printf '\\033[?1049h\\033[2J\\033[H\\033[31mFULLSCREEN_%s\\033[0m' LIVE\r")
        expect('FULLSCREEN_LIVE')
        send(b'\x02d');expect('TERMINAL SESSIONS');send(b'a')
        expect('FULLSCREEN_LIVE')
        location=next((y,line.index('FULLSCREEN_LIVE')) for y,line in enumerate(screen.display) if 'FULLSCREEN_LIVE' in line)
        assert screen.buffer[location[0]][location[1]].fg == 'cd0000', screen.buffer[location[0]][location[1]]
        send(b"printf '\\033[?1049l'\r");expect('TOKEN=retained-alpha')
        preview(screen,'remote-terminal')
        print('PASS: alternate-screen contents and ANSI color survive detach/attach',flush=True)
        # Changing the viewer size changes the real destination PTY (one row reserved for Kiln).
        screen.resize(lines=24,columns=80)
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0));os.kill(child.pid,signal.SIGWINCH);pump(.4)
        send(b'stty size\r');expect('23 80')
        send(b'\x02w');expect('TERMINAL SESSIONS');pump(.4);preview(screen,'session-picker')
        assert command('session attach alpha',False).returncode!=0
        send(b'a');expect('1:alpha |')
        # The session service owns both PTYs across graceful and abrupt dashboard restarts.
        service_pid=(tmp/'state/session-service.pid').read_text()
        send(b'printf "BEFORE_RESTART=%s\\n" "$KILN_SESSION_TOKEN"\r');expect('BEFORE_RESTART=retained-alpha')
        for abrupt in [False,True]:
            if abrupt:runtime.kill()
            else:runtime.terminate()
            pump(.5);runtime.wait(timeout=10);child.wait(timeout=10)
            if abrupt:time.sleep(6.5)
            runtime=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(tmp/'admin.pub'),'--port',str(jumpport)],stdout=log,stderr=log)
            deadline=time.monotonic()+10
            while command('status',False).returncode:assert time.monotonic()<deadline;time.sleep(.1)
            assert (tmp/'state/session-service.pid').read_text()==service_pid
            child,master,screen=connect();stream=pyte.ByteStream(screen);expect('6 Servers');attach('alpha')
            send(b'printf "AFTER_RESTART=%s\\n" "$KILN_SESSION_TOKEN"\r');expect('AFTER_RESTART=retained-alpha')
        print('PASS: remote shell and session-service PID survive clean restart and SIGKILL of dashboard',flush=True)
        # A second interactive viewer cannot silently steal input ownership.
        first=(child,master,screen,stream)
        child,master,screen=connect();stream=pyte.ByteStream(screen);expect('5 Sessions')
        send(b'`session attach alpha\r');expect('already attached')
        send(b'\x1b');pump(.3);send(b'q');child.wait(timeout=5)
        child,master,screen,stream=first
        print('PASS: PTY resize, picker and exclusive input ownership',flush=True)
        command('session close alpha');expect('TERMINAL SESSIONS')
        pump(1.2)
        send(b'\r');expect('Rename');click('Rename');send(b'\x15renamed\r');expect('Renamed session')
        assert 'renamed' in command('session list').stdout
        send(b'\r');click('Close session');expect('may be lost');send(b'\x1b');pump(.3)
        assert 'renamed' in command('session list').stdout
        send(b'\r');click('Close session');click('Confirm');expect('Closed session renamed')
        send(b'6\r');click('Edit server');expect('Host:');send(b'\x15localhost\r\r\r');expect('Destination changed')
        assert 'unverified' in command('server list').stdout
        send(b'\r');click('Remove server');click('Confirm');expect('Removed fixture')
        print('PASS: menu rename, cancel/confirm close, destination edit resets trust, confirmed removal',flush=True)

        assert 'No sessions' in command('session list').stdout
        send(b'q');child.wait(timeout=5)
        print('PASS: explicit close ends sessions; viewer quit leaves Kiln healthy',flush=True)
    except BaseException:
        log.flush();sshlog.flush();print((tmp/'runtime.log').read_text());print((tmp/'sshd.log').read_text());raise
    finally:
        for child,fd in clients:
            if child.poll() is None:child.kill();child.wait(timeout=5)
            os.close(fd)
        if runtime.poll() is None:
            for name in ['alpha','beta','renamed']:command('session close '+name,False)
            if keycreated:command('server remove fixture',False);command('key delete fixture',False)
            runtime.terminate();runtime.wait(timeout=15)
        if destination and destination.poll() is None:destination.terminate();destination.wait(timeout=5)
        log.close();sshlog.close()

        # The detached session service has its own lifetime; explicitly stop test fixtures.
        for pidfile in tmp.rglob("session-service.pid"):
            subprocess.run([str(BIN/"kiln"),"session-service-stop","--state",str(pidfile.parent)],capture_output=True,timeout=10)
