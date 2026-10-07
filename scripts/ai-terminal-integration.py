#!/usr/bin/env python3
"""Opt-in live Erebine test of the native SSH chat view. Requires pyte and Pillow."""
import argparse,fcntl,json,os,pathlib,pty,select,shutil,socket,struct,subprocess,tempfile,termios,time
import pyte
p=argparse.ArgumentParser();p.add_argument('--state-source',type=pathlib.Path,required=True);p.add_argument('--preview',type=pathlib.Path);a=p.parse_args()
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/release'))
def freeport():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='kiln-ai-ui-') as td:
 root=pathlib.Path(td);state=root/'state';state.mkdir(mode=0o700);key=root/'admin';port=freeport();api=freeport()
 for name in ['ai.json','vault-config.json','vault.enc']:shutil.copy2(a.state_source/name,state/name)
 subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
 log=open(root/'log','w');runtime=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--port',str(port)],stdout=log,stderr=log)
 client=None;master=None
 try:
  deadline=time.monotonic()+10
  while not (state/'ssh-host-ed25519.pub').exists():assert time.monotonic()<deadline;time.sleep(.1)
  known=root/'known';known.write_text(f'[127.0.0.1]:{port} '+(state/'ssh-host-ed25519.pub').read_text())
  base=['ssh','-F','/dev/null','-e','none','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}','-i',str(key),'-p',str(port)]
  def command(c):
   r=subprocess.run(base+['admin@127.0.0.1',c],capture_output=True,text=True,timeout=15);assert r.returncode==0,r.stdout;return r.stdout
  time.sleep(.3)
  path=root/'app.json';path.write_text(json.dumps(dict(application='ai-ui',name='worker',version='26.10.07.3',executable=str(BIN/'kiln-example-backend'),arguments=['--port',str(api)],healthURL=f'http://127.0.0.1:{api}/health')))
  command(f'app install {path}');command('app start ai-ui/worker')
  master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',38,120,0,0))
  client=subprocess.Popen(base+['-tt','admin@127.0.0.1'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'});os.close(slave)
  screen=pyte.Screen(120,38);stream=pyte.ByteStream(screen)
  def pump(seconds=.2):
   end=time.monotonic()+seconds
   while time.monotonic()<end:
    ready,_,_=select.select([master],[],[],max(0,end-time.monotonic()))
    if ready:stream.feed(os.read(master,65536))
  def expect(text,seconds=120):
   end=time.monotonic()+seconds
   while text not in '\n'.join(screen.display):pump(.1);assert time.monotonic()<end,(text,'\n'.join(screen.display))
  def send(data):os.write(master,data);pump()
  expect('Overview',10);send(b'`');send(b'ai\r');expect('KILN AI CHAT')
  send(b'Use list_modules and module_health to report the running service and its health. Keep it brief.\r')
  expect('[working]');expect('[ready]')
  rendered='\n'.join(screen.display);assert 'ai-ui/worker' in rendered,rendered;assert 'healthy' in rendered.lower(),rendered
  if a.preview:
   from PIL import Image,ImageDraw,ImageFont
   font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',15);cw,ch=10,22
   im=Image.new('RGB',(1232,868),'#1c1c1c');d=ImageDraw.Draw(im)
   def color(v,default):return default if v=='default' else '#'+v if len(v)==6 else v
   for y in range(38):
    for x in range(120):
     cell=screen.buffer[y][x];xx,yy=16+x*cw,16+y*ch
     d.rectangle((xx,yy,xx+cw,yy+ch),fill=color(cell.bg,'#1c1c1c'));d.text((xx,yy),cell.data,font=font,fill=color(cell.fg,'#ddd'),anchor='la')
   a.preview.parent.mkdir(parents=True,exist_ok=True);im.save(a.preview)
  send(b'/exit\r');expect('COMMAND DRAWER')
  print('PASS: real SSH native AI chat, live Erebine tools, health report, wrapped rendering and exit',flush=True)
 finally:
  if client and client.poll() is None:client.kill();client.wait(timeout=5)
  if master is not None:os.close(master)
  if runtime.poll() is None:runtime.terminate();runtime.wait(timeout=15)
  subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
  log.close()
