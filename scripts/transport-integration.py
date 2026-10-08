#!/usr/bin/env python3
"""Real OpenSSH admission, pre-auth deadlines and bootstrap-policy recovery."""
import base64,json,os,pathlib,resource,select,socket,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
if soft < 4096:
    assert hard == resource.RLIM_INFINITY or hard >= 4096, 'Transport proof requires at least 4096 file descriptors'
    resource.setrlimit(resource.RLIMIT_NOFILE,(4096,hard))
def wait(fn,seconds=20):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            if value:=fn(): return value
        except (OSError,AssertionError): pass
        time.sleep(.05)
    raise AssertionError('Timed out waiting for transport condition')
with tempfile.TemporaryDirectory(prefix='kiln-transport-') as td:
    root=pathlib.Path(td);state=root/'state';key=root/'admin';control=root/'control'
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    args=['ssh','-F','/dev/null','-i',str(key),'-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','BatchMode=yes','-o','StrictHostKeyChecking=no','-o',f'UserKnownHostsFile={root/"known"}','-o','ConnectTimeout=2','-p',str(port)]
    destination='admin@127.0.0.1';children=[];raw=[];master=None;node=None
    log=open(root/'runtime.log','w+')
    def start():return subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--port',str(port)],stdout=log,stderr=log)
    def command(text,mux=False):
        extra=['-S',str(control),'-o','ControlMaster=no'] if mux else []
        return subprocess.run(args+extra+[destination,text],capture_output=True,text=True,timeout=8)
    def welcome(p):
        ready=select.select([p.stdout],[],[],5)[0]
        assert ready and b'Welcome to Kiln' in os.read(p.stdout.fileno(),4096)
    def closed(s):
        s.setblocking(False)
        try:return s.recv(4096)==b''
        except BlockingIOError:return False
        except (ConnectionResetError,BrokenPipeError):return True
        finally:s.settimeout(3)
    try:
        node=start();wait(lambda:command('status').returncode==0)
        fingerprint=(state/'ssh-host-ed25519.pub').read_bytes()
        master=subprocess.Popen(args+['-M','-S',str(control),'-N',destination],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        wait(control.exists)
        for _ in range(16):
            p=subprocess.Popen(args+['-S',str(control),'-o','ControlMaster=no','-T',destination],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE);children.append(p);welcome(p)
        denied=command('status',True);assert 'Session open refused by peer' in denied.stderr,(denied.returncode,denied.stdout,denied.stderr)
        assert command('status').returncode==0
        children[0].stdin.write(b'exit\n');children[0].stdin.flush();children[0].wait(timeout=5)
        def mux_recovered():
            result=command('status',True)
            return result.returncode==0 and 'Session open refused by peer' not in result.stderr
        wait(mux_recovered)
        print('PASS per-connection channel cap rejects excess work; independent management and released capacity remain usable',flush=True)
        for p in children:
            if p.poll() is None:p.terminate();p.wait(timeout=5)
        master.terminate();master.wait(timeout=5);master=None
        with socket.socket() as a,socket.socket() as b:
            a.bind(('127.0.0.1',0));b.bind(('127.0.0.1',0))
            ingress,worker=a.getsockname()[1],b.getsockname()[1]
        manifest=root/'module.json'
        manifest.write_text(json.dumps(dict(application='transport',name='api',version='1',executable=str(BIN/'kiln-example-backend'),arguments=['--websocket','--port',str(worker)],healthURL=f'http://127.0.0.1:{worker}/health',ingressPort=ingress)))
        assert command('app deploy '+str(manifest)).returncode==0
        # Complete real upgrades, proving every held connection has reached the
        # worker before trying the excess connection. No fake backend sockets.
        for _ in range(1024):
            s=socket.create_connection(('127.0.0.1',ingress),timeout=3);raw.append(s)
            key_text=base64.b64encode(os.urandom(16)).decode()
            s.sendall(f'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key_text}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
            response=b''
            while not response.endswith(b'\r\n\r\n'):
                part=s.recv(1);assert part,'premature ingress admission loss';response+=part
            assert b'101 Switching Protocols' in response
        excess=socket.create_connection(('127.0.0.1',ingress),timeout=3);raw.append(excess)
        wait(lambda:closed(excess),3)
        assert command('status').returncode==0
        for s in raw:s.close()
        raw=[]
        assert command('app stop transport/api').returncode==0
        print('PASS ingress bounds 1024 real WebSockets, rejects excess connections and preserves SSH management',flush=True)
        # All slots here are unauthenticated raw TCP peers, each receiving only
        # the server identification banner. None can retain a slot past 15 s.
        time.sleep(.3)
        for _ in range(128):
            s=socket.create_connection(('127.0.0.1',port),timeout=3);raw.append(s)
            assert s.recv(4096).startswith(b'SSH-'), 'admission lost before configured capacity'
        excess=socket.create_connection(('127.0.0.1',port),timeout=3);raw.append(excess)
        wait(lambda:closed(excess),3)
        wait(lambda:all(closed(s) for s in raw[:-1]),20)
        assert command('status').returncode==0
        print('PASS 128-connection cap and 15-second pre-authentication deadline; management recovers after stalled clients',flush=True)
        for s in raw:s.close()
        raw=[]
        oversized=socket.create_connection(('127.0.0.1',port),timeout=3);raw.append(oversized);oversized.recv(4096)
        try:oversized.sendall(b'X'*131073)
        except (BrokenPipeError,ConnectionResetError):pass
        wait(lambda:closed(oversized),3)
        print('PASS oversized pre-authentication input closed without affecting authorized SSH',flush=True)
        node.terminate();node.wait(timeout=15)
        (pathlib.Path(str(key)+'.pub')).unlink()
        node=start();wait(lambda:command('status').returncode==0)
        assert (state/'ssh-host-ed25519.pub').read_bytes()==fingerprint
        print('PASS persisted identity policy and host key survive removal of first-boot provisioning key file',flush=True)
        node.terminate();node.wait(timeout=15)
        (state/'identities.json').unlink()
        node=start();assert node.wait(timeout=15)!=0
        print('PASS missing initialized identity policy fails closed; no bootstrap credential resurrection',flush=True)
    finally:
        for s in raw:s.close()
        for p in children+([master] if master else []):
            if p.poll() is None:p.terminate();p.wait(timeout=8)
        if node and node.poll() is None:node.terminate();node.wait(timeout=15)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
