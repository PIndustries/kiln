#!/usr/bin/env python3
"""Opt-in paid API check against configured Erebine, using isolated disposable workers."""
import argparse,json,os,pathlib,queue,re,shutil,socket,subprocess,tempfile,threading,time
p=argparse.ArgumentParser();p.add_argument('--state-source',type=pathlib.Path,required=True);a=p.parse_args()
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=pathlib.Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug'))
with tempfile.TemporaryDirectory(prefix='kiln-ai-live-') as td:
 root=pathlib.Path(td);state=root/'state';state.mkdir(mode=0o700)
 for name in ['ai.json','vault-config.json','vault.enc']: shutil.copy2(a.state_source/name,state/name)
 with socket.socket() as listener: listener.bind(('127.0.0.1',0)); port=listener.getsockname()[1]
 manifest=root/'worker.json';manifest.write_text(json.dumps(dict(application='ai-test',name='worker',version='26.10.07.3',executable=str(BIN/'kiln-example-backend'),arguments=['--port',str(port)],healthURL=f'http://127.0.0.1:{port}/health')))
 server=subprocess.Popen([str(BIN/'kiln'),'up','--no-ssh','--console','--state',str(state)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
 output=queue.Queue()
 def reader():
  for line in server.stdout: output.put(line)
 threading.Thread(target=reader,daemon=True).start()
 def until(marker,timeout=180):
  lines=[];end=time.monotonic()+timeout
  while time.monotonic()<end:
   try: line=output.get(timeout=1)
   except queue.Empty: continue
   lines.append(line)
   if marker in line: return ''.join(lines)
  raise AssertionError('Timed out waiting for '+marker)
 def command(text):
  server.stdin.write(text+'\nstatus\n');server.stdin.flush()
  return until('Automatic restart and clustering:')
 try:
  until('Kiln runtime ready')
  assert 'Installed' in command(f'app install {manifest}')
  started=command('app start ai-test/worker');pid=int(re.search(r'pid=(\d+)',started).group(1))
  time.sleep(.3); assert 'healthy' in command('app health ai-test/worker')
  report=command('ai ask Use list_modules and host_metrics to report current Kiln state. Keep the answer brief.')
  assert 'Error:' not in report,report
  assert 'ai-test' in report and 'worker' in report,report
  print('LIVE REPORT:\n'+report,flush=True)
  proposal=command('ai ask Please stop ai-test/worker. Use request_operation to propose it; do not claim it has executed.')
  assert 'Error:' not in proposal,proposal
  match=re.search(r'Outside chat: ai approve ([a-f0-9-]+)',proposal);assert match,proposal
  os.kill(pid,0)
  print('PASS: live Erebine tool calling produced proposal; worker remains running before approval',flush=True)
  result=command('ai approve '+match.group(1));assert 'Executed approved operation: Stopped ai-test/worker' in result,result
  assert 'Unknown proposal' in command('ai approve '+match.group(1))
  print('PASS: explicit approval stopped disposable worker; replay rejected',flush=True)
  pack=root/'knowledge.json';pack.write_text(json.dumps(dict(version='test-knowledge-1',notes='The disposable ai-test/worker is used only for integration validation.')))
  assert 'without a restart' in command(f'ai knowledge install {pack}')
  assert 'test-knowledge-1' in command('ai status')
  print('PASS: versioned knowledge pack updated without restarting Kiln',flush=True)
 finally:
  if server.poll() is None: server.terminate();server.wait(timeout=15)
  subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=8)
