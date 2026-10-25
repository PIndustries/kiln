#!/usr/bin/env python3
"""Real macOS compiler/runtime isolation with disposable sentinels; no secrets."""
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
BIN=Path(os.environ.get('KILN_BIN_DIR',ROOT/'.build/debug')).resolve()
assert platform.system()=='Darwin','No unsandboxed fallback'
with tempfile.TemporaryDirectory(prefix='kiln-web-isolation-') as td:
    root=Path(td).resolve(); job=root/'job'; job.mkdir(mode=0o700); data=root/'data'; data.mkdir(mode=0o700)
    sentinel=root/'outside'; sentinel.write_text('DISPOSABLE_SENTINEL')
    subprocess.run(['python3',str(ROOT/'scripts/export-web-sdk.py'),'--build-dir',str(BIN),'--output',str(job/'sdk.json')],check=True)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0)); listener.listen(); outbound=listener.getsockname()[1]
        with socket.socket() as portProbe:
            portProbe.bind(('127.0.0.1',0)); port=portProbe.getsockname()[1]
        source='''import Foundation
import Darwin
@main struct Probe {
 static func main() throws {
  let outside=URL(fileURLWithPath: OUTSIDE)
  let deniedRead=(try? Data(contentsOf:outside)) == nil
  let deniedWrite=(try? Data("changed".utf8).write(to:outside)) == nil
  let child=Process(); child.executableURL=URL(fileURLWithPath:"/usr/bin/true")
  var deniedFork=false
  do { try child.run(); child.waitUntilExit() } catch { deniedFork=true }
  let sock=socket(AF_INET,SOCK_STREAM,0); defer { close(sock) }
  var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family=sa_family_t(AF_INET); address.sin_port=UInt16(OUTBOUND).bigEndian
  inet_pton(AF_INET,"127.0.0.1",&address.sin_addr)
  let deniedOutbound=withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(sock,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 } }
  let own=URL(fileURLWithPath:ProcessInfo.processInfo.environment["KILN_DATA_DIR"]!).appendingPathComponent("own")
  try Data("own data".utf8).write(to:own)
  let result=["deniedRead":deniedRead,"deniedWrite":deniedWrite,"deniedFork":deniedFork,"deniedOutbound":deniedOutbound,"cleanEnvironment":ProcessInfo.processInfo.environment["KILN_TEST_SECRET"] == nil,"ownData":(try Data(contentsOf:own)) == Data("own data".utf8)]
  print(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
 }
}'''.replace('OUTSIDE',json.dumps(str(sentinel))).replace('OUTBOUND',str(outbound))
        (job/'App.swift').write_text(source)
        build=subprocess.run([str(BIN/'kiln-web-builder'),str(job)],capture_output=True,text=True,timeout=120)
        assert build.returncode==0,build.stderr[:4000]
        binary=job/'app'; sdk=json.loads((job/'sdk.json').read_text())
        environment={**os.environ,'KILN_DATA_DIR':str(data),'KILN_PORT':str(port),'KILN_TEST_SECRET':'DISPOSABLE_TEST_VALUE'}
        run=subprocess.run([str(BIN/'kiln-web-runtime'),str(binary),hashlib.sha256(binary.read_bytes()).hexdigest(),json.dumps(sdk['runtimeLibraries'])],env=environment,capture_output=True,text=True,timeout=20)
        assert run.returncode==0,run.stderr[:4000]
        result=json.loads(run.stdout); assert all(result.values()),result
        assert sentinel.read_text()=='DISPOSABLE_SENTINEL'
        print('PASS: sandboxed compiler and runtime; outside read/write, child process and outbound network denied; credentials stripped; own data allowed')
        binary.write_bytes(binary.read_bytes()+b'tamper')
        rejected=subprocess.run([str(BIN/'kiln-web-runtime'),str(binary),'0'*64,json.dumps(sdk['runtimeLibraries'])],env=environment,capture_output=True,text=True,timeout=10)
        assert rejected.returncode!=0
        print('PASS: changed executable digest is rejected before execution')
