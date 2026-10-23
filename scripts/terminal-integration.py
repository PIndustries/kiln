#!/usr/bin/env python3
"""Real SSH PTY interaction. Test dependencies: pyte; Pillow for optional previews."""
import argparse, fcntl, json, os, pathlib, pty, select, signal, socket, struct, subprocess, tempfile, termios, time
import pyte
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(); p.add_argument('--preview',type=pathlib.Path); a=p.parse_args()
BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
def freeport():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def preview(screen,path):
    from PIL import Image, ImageDraw, ImageFont
    font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',15)
    cw,ch=10,22
    img=Image.new('RGB',(screen.columns*cw+32,screen.lines*ch+32),'#1c1c1c'); d=ImageDraw.Draw(img)
    def color(value,default):
        if value=='default': return default
        if len(value)==6: return '#'+value
        return value
    for y in range(screen.lines):
        for x in range(screen.columns):
            cell=screen.buffer[y][x]; xx,yy=16+x*cw,16+y*ch
            d.rectangle((xx,yy,xx+cw,yy+ch),fill=color(cell.bg,'#1c1c1c'))
            d.text((xx,yy),cell.data,font=font,fill=color(cell.fg,'#ddd'),anchor='la')
    path.parent.mkdir(parents=True,exist_ok=True); img.save(path)

with tempfile.TemporaryDirectory(prefix='kiln-terminal-') as tmp:
    tmp=pathlib.Path(tmp); port=freeport(); api=freeport(); ws=freeport()
    key=tmp/'key'; subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    log=open(tmp/'log','w')
    runtime=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(tmp/'state'),'--authorized-keys',str(key)+'.pub','--port',str(port)],stdout=log,stderr=log)
    clients=[]
    try:
        deadline=time.monotonic()+10
        while not (tmp/'state/ssh-host-ed25519.pub').exists():
            assert time.monotonic()<deadline; time.sleep(.1)
        (tmp/'known').write_text(f'[127.0.0.1]:{port} '+(tmp/'state/ssh-host-ed25519.pub').read_text())
        base=['ssh','-F','/dev/null','-e','none','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o',f'UserKnownHostsFile={tmp}/known','-o','StrictHostKeyChecking=yes','-i',str(key),'-p',str(port)]
        # Listener comes up after the identity is written.
        while True:
            r=subprocess.run(base+['admin@127.0.0.1','status'],capture_output=True,text=True)
            if r.returncode==0: break
            assert time.monotonic()<deadline; time.sleep(.1)
        for name,listen,extra in [('rest',api,[]),('websocket',ws,['--websocket'])]:
            path=tmp/(name+'.json'); path.write_text(json.dumps(dict(application='storefront',name=name,version='0.1.0',executable=str(BIN/'kiln-example-backend'),arguments=['--port',str(listen)]+extra,healthURL=f'http://127.0.0.1:{listen}/health')))
            for command in [f'app install {path}',f'app start storefront/{name}']:
                r=subprocess.run(base+['admin@127.0.0.1',command],capture_output=True,text=True); assert r.returncode==0,r.stdout
        def connect():
            master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0))
            process=subprocess.Popen(base+['-tt','admin@127.0.0.1'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'})
            os.close(slave); clients.append((process,master)); return process,master
        process,master=connect(); screen=pyte.Screen(100,30); stream=pyte.ByteStream(screen); raw=bytearray()
        def pump(seconds=.2):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                ready,_,_=select.select([master],[],[],max(0,deadline-time.monotonic()))
                if ready:
                    try: data=os.read(master,65536)
                    except OSError: break
                    if not data: break
                    raw.extend(data); stream.feed(data)
        def expect(text,seconds=5):
            deadline=time.monotonic()+seconds
            while text not in '\n'.join(screen.display):
                pump(.1)
                assert time.monotonic()<deadline, (text,'\n'.join(screen.display))
        def send(data): os.write(master,data); pump()
        expect('storefront/websocket')
        assert b'\x1b[?1049h' in raw and b'\x1b[38;5;' in raw
        def click_text(text):
            for y,line in enumerate(screen.display):
                x=line.find(text)
                if x>=0:
                    send(f'\x1b[<0;{x+2};{y+1}M\x1b[<0;{x+2};{y+1}m'.encode()); return
            raise AssertionError(('Missing click target',text))
        assert b'\x1b[48;5;0m' in raw and b'\x1b[38;5;46m' in raw
        send(b'`theme cyan\r'); expect('Session theme updated')
        assert b'\x1b[38;5;51m' in raw
        send(b'theme default\r'); expect('Session theme updated')
        send(b'`')
        assert b'\x1b[?1000h' in raw and b'\x1b[?1006h' in raw
        click_text('3 Metrics'); expect('CPU:')
        before=next(line for line in screen.display if 'Sample:' in line)
        pump(1.3)
        after=next(line for line in screen.display if 'Sample:' in line)
        assert before != after, 'Metrics sample did not stream'
        expect('RSS MiB')
        if a.preview: preview(screen,a.preview/'kiln-metrics.png')
        click_text('1 Overview'); expect('SELECTED SERVICE')
        service_row=next(y for y,line in enumerate(screen.display) if 'storefront/rest' in line)
        click_text('storefront/rest'); expect('Manage storefront/rest')
        menu_row=next(y for y,line in enumerate(screen.display) if 'Manage storefront/rest' in line)
        assert menu_row == service_row+1, 'Menu must stay beside selected row'
        assert screen.display[menu_row].index('Manage') > 2
        if a.preview: preview(screen,a.preview/'kiln-row-menu.png')
        click_text('Back'); pump(.2)
        if a.preview: preview(screen,a.preview/'kiln-dashboard.png')
        send(b'\r'); expect('Manage storefront/rest')
        send(b'\x1b[B\r'); expect('Confirm: app stop storefront/rest')
        send(b'\x1b'); pump(.3)
        assert 'Confirm:' not in '\n'.join(screen.display)
        send(b'\r\x1b[B\x1b[B\x1b[B\r'); expect('healthy (HTTP 200)')
        send(b'`'); expect('COMMAND DRAWER')
        send(b'app li\t'); expect('kiln > app list')
        send(b'\r'); expect('APPLICATION')
        if a.preview: preview(screen,a.preview/'kiln-command-drawer.png')
        send(b'\x1b[A'); expect('kiln > app list')
        send(b'\x03')
        send(b'\x1b[200~status\nexit\x1b[201~'); expect('kiln > status exit')
        assert process.poll() is None
        send(b'\x03\x1b'); pump(.3)
        screen.resize(lines=24,columns=80)
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0)); os.kill(process.pid,signal.SIGWINCH); pump(.5)
        expect('storefront/websocket')
        if a.preview: preview(screen,a.preview/'kiln-80-columns.png')
        screen.resize(lines=10,columns=30)
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',10,30,0,0)); os.kill(process.pid,signal.SIGWINCH); pump(.5)
        expect('Terminal too small')
        screen.resize(lines=30,columns=100)
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0)); os.kill(process.pid,signal.SIGWINCH); pump(.5)
        expect('storefront/rest')
        # Validate real window-change events beyond the old 240x100 viewport cap.
        for columns,rows in [(320,120),(164,42),(80,24)]:
            screen.resize(lines=rows,columns=columns)
            fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',rows,columns,0,0))
            os.kill(process.pid,signal.SIGWINCH); pump(.3)
            send(b'\r'); expect('Manage storefront/rest')
            service_row=next(y for y,line in enumerate(screen.display) if '> storefront/rest' in line)
            menu_row=next(y for y,line in enumerate(screen.display) if 'Manage storefront/rest' in line)
            assert menu_row == service_row+1
            click_text('Back')
            send(b'`'); expect('='*(columns-5))
            assert 'COMMAND DRAWER' in '\n'.join(screen.display)
            send(b'`')
        send(b'\x1b[B\r\x1b[B\r'); expect('Confirm: app stop storefront/websocket')
        send(b'\r'); expect('Stopped storefront/websocket')
        send(b'\r\r'); expect('Started storefront/websocket')
        send(b'q'); process.wait(timeout=5); pump()
        assert b'\x1b[?1049l' in raw and b'\x1b[?25h' in raw and b'\x1b[?1000l' in raw and b'\x1b[?1006l' in raw
        assert process.returncode==0
        process,master=connect(); screen=pyte.Screen(100,30); stream=pyte.ByteStream(screen); raw=bytearray()
        expect('storefront/rest')
        runtime.terminate(); pump(1); runtime.wait(timeout=12); process.wait(timeout=5); pump(.1)
        assert b'\x1b[?1000l' in raw and b'\x1b[?1006l' in raw and b'\x1b[?1049l' in raw
        print('PASS: SSH dashboard, mouse clicks, streaming host metrics, colors, menus, confirmation, stop/start actions, health action, completion, history, paste, resize, terminal cleanup including server shutdown')
    finally:
        for process,master in clients:
            if process.poll() is None: process.kill(); process.wait(timeout=5)
            os.close(master)
        runtime.terminate(); runtime.wait(timeout=12); log.close()

        # The detached session service has its own lifetime; explicitly stop test fixtures.
        for pidfile in tmp.rglob("session-service.pid"):
            subprocess.run([str(BIN/"kiln"),"session-service-stop","--state",str(pidfile.parent)],capture_output=True,timeout=10)
