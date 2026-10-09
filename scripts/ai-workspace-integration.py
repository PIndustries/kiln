#!/usr/bin/env python3
"""Opt-in live Erebine test of sidebar approvals and background tasks. Requires pyte and optional Pillow."""
import argparse,fcntl,json,os,pathlib,pty,re,select,shutil,socket,struct,subprocess,tempfile,termios,time
import pyte,signal
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
  expect('7 AI Chat',10);send(b'7');expect('TASKS & APPROVALS')
  send(b'Use propose_operation to propose restarting ai-ui/worker. Do not execute it.\r')
  expect('APPROVAL / restart',180)
  expect('[ready]',180)
  send(b'\x1b[<0;5;8M');expect('REVIEW OPERATION')
  expect('app restart ai-ui/worker')
  if a.preview:
   from PIL import Image,ImageDraw,ImageFont
   font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',15);cw,ch=10,22
   im=Image.new('RGB',(1232,868),'#1c1c1c');d=ImageDraw.Draw(im)
   def color(v,default):return default if v=='default' else '#'+v if len(v)==6 else v
   for y in range(38):
    for x in range(120):
     cell=screen.buffer[y][x];xx,yy=16+x*cw,16+y*ch
     d.rectangle((xx,yy,xx+cw,yy+ch),fill=color(cell.bg,'#1c1c1c'));d.text((xx,yy),cell.data,font=font,fill=color(cell.fg,'#ddd'),anchor='la')
   im.save(a.preview)
  before=command('app list')
  send(b'\x1b[<0;45;36M')
  expect('Proposal declined');expect('0 approvals')
  assert command('app list')==before,'Deny changed worker'
  print('PASS actual Erebine proposal -> sidebar -> review -> mouse Deny; worker unchanged',flush=True)
  send(b'Create another pending restart proposal for ai-ui/worker using propose_operation.\r')
  expect('APPROVAL / restart',180);expect('[ready]',180)
  send(b'\t');send(b'\r');expect('REVIEW OPERATION')
  send(b'\r');expect('[ready]',30)
  assert command('app list')!=before,'Approve did not change worker PID'
  expect('0 approvals')
  print('PASS keyboard sidebar review -> approve; worker PID changed; proposal consumed',flush=True)
  send(b'Report the current Kiln release briefly.')
  send(b'\x1b[<0;5;4M');expect('Task created:',30)
  expect('TASK /',30)
  send(b'\x1b[<0;5;8M');expect('Task ',30)
  print('PASS create background task from composer and inspect via sidebar click',flush=True)
  end=time.monotonic()+180
  while 'TASK / completed' not in '\n'.join(screen.display):
   pump(.2);frame='\n'.join(screen.display)
   assert 'TASK / failed' not in frame and time.monotonic()<end,frame
  print('PASS task completion appears live in sidebar',flush=True)
  fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
  screen.resize(lines=24,columns=80);os.kill(client.pid,signal.SIGWINCH);pump(.5)
  send(b'\t');expect('TASKS & APPROVALS')
  send(b'\t');expect('KILN AI CHAT')
  print('PASS narrow terminal Tab navigation',flush=True)

 finally:
  if client and client.poll() is None:client.kill();client.wait(timeout=5)
  if master is not None:os.close(master)
  if runtime.poll() is None:runtime.terminate();runtime.wait(timeout=15)
  subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
  log.close()
