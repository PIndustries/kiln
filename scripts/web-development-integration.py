#!/usr/bin/env python3
"""Real SSH -> fixture AI tools -> sandboxed Swift compile -> managed deploy.
macOS only, standard library, no credentials or external model traffic.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('KILN_BIN_DIR', ROOT / '.build/debug')).resolve()
if platform.system() != 'Darwin':
    raise SystemExit('This acceptance requires the macOS sandbox; no unsandboxed fallback')

def freeport():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def wait(check, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise AssertionError('Timed out waiting for acceptance state')

class Fixture(http.server.BaseHTTPRequestHandler):
    redirect_requests = 0
    def do_GET(self):
        Fixture.redirect_requests += 1
        self.send_response(500); self.end_headers()
    def log_message(self, *_): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/api/chat'
        assert 'update_web_source' in [t['function']['name'] for t in body['tools']]
        messages = body['messages']
        prompt = next(m['content'] for m in reversed(messages) if m['role'] == 'user')
        tool_results = [m for m in messages if m['role'] == 'tool']
        if 'KILN PROJECT REFACTOR / functions' in prompt:
            assert 'request_operation' not in [t['function']['name'] for t in body['tools']]
            if not tool_results: name,args='tool_help',dict(topic='web')
            elif tool_results[-1]['tool_name']=='tool_help':
                assert '1–32 operations' in tool_results[-1]['content'] and '262144' in tool_results[-1]['content']
                name,args='list_web_files',dict(module='dev/site')
            elif tool_results[-1]['tool_name']=='list_web_files': name,args='read_web_file',dict(module='dev/site',path='App.swift',offset='0')
            elif tool_results[-1]['tool_name']=='read_web_file':
                page=json.loads(tool_results[-1]['content'])
                if not page['complete']: name,args='read_web_file',dict(module='dev/site',path='App.swift',offset=str(page['nextOffset']))
                else: name,args='validate_web_source',dict(module='dev/site',edits=json.dumps(Fixture.refactor_operations))
            elif tool_results[-1]['tool_name']=='validate_web_source':
                assert 'Isolated compile passed' in tool_results[-1]['content'],tool_results[-1]['content']
                name,args='update_web_source',dict(module='dev/site',edits=json.dumps(Fixture.refactor_operations))
            else: raise AssertionError('Unexpected refactor phase')
        elif 'component' in prompt:
            deleting = 'Delete' in prompt
            before, after = (r'\(projectHeading())', 'Built through Kiln AI.') if deleting else ('Built through Kiln AI.', r'\(projectHeading())')
            operations = [dict(path='App.swift', before=before, after=after)]
            if deleting:
                read = next((json.loads(m['content']) for m in tool_results if m.get('tool_name')=='read_web_file' and json.loads(m['content'])['file']=='Components/Heading.swift'), None)
                if read: operations.append(dict(path='Components/Heading.swift',action='delete',sha256=read['sha256']))
            else:
                operations.append(dict(path='Components/Heading.swift',action='create',content='import Foundation\nfunc projectHeading() -> String { "Multi-file published." }\n'))
            if not tool_results: name, args = 'tool_help', dict(topic='web')
            elif tool_results[-1]['tool_name']=='tool_help': name, args = 'list_web_files', dict(module='dev/site')
            elif tool_results[-1]['tool_name']=='list_web_files': name, args = 'read_web_file', dict(module='dev/site',path='Components/Heading.swift' if deleting else 'App.swift',offset='0')
            elif tool_results[-1]['tool_name']=='read_web_file':
                page=json.loads(tool_results[-1]['content'])
                if not page['complete']: name, args = 'read_web_file',dict(module='dev/site',path=page['file'],offset=str(page['nextOffset']))
                elif page['file']=='Components/Heading.swift': name, args = 'read_web_file',dict(module='dev/site',path='App.swift',offset='0')
                else: name, args = 'validate_web_source',dict(module='dev/site',edits=json.dumps(operations))
            elif tool_results[-1]['tool_name']=='validate_web_source':
                assert 'Isolated compile passed' in tool_results[-1]['content'],tool_results[-1]['content']
                name, args = 'update_web_source',dict(module='dev/site',edits=json.dumps(operations))
            else: raise AssertionError('Unexpected project phase')
        elif not tool_results:
            name, args = 'tool_help', dict(topic='web')
        elif tool_results[-1]['tool_name'] == 'tool_help':
            assert 'KILNWEB GUIDE' in tool_results[-1]['content'] and 'validate_web_source' in tool_results[-1]['content']
            name, args = 'list_web_projects', {}
        elif tool_results[-1]['tool_name'] == 'list_web_projects':
            assert 'dev/site' in tool_results[-1]['content']
            name, args = 'read_web_source', dict(module='dev/site', offset='0')
        elif tool_results[-1]['tool_name'] == 'read_web_source':
            source = json.loads(tool_results[-1]['content'])
            assert source['file'] == 'App.swift' and source['sha256']
            if not source['complete']:
                name, args = 'read_web_source', dict(module='dev/site', offset=str(source['nextOffset']))
            elif 'broken' in prompt:
                name, args = 'update_web_source', dict(module='dev/site', edits=json.dumps([dict(before='import Foundation', after='THIS IS NOT SWIFT')]))
            else:
                # First try a broken proposal in the build-only lane. The AI
                # fixture must receive diagnostics and repair it before publish.
                name, args = 'validate_web_source', dict(module='dev/site', edits=json.dumps([dict(before='import Foundation', after='THIS IS NOT SWIFT')]))
        elif tool_results[-1]['tool_name'] == 'validate_web_source':
            content = tool_results[-1]['content']
            assert Fixture.source_path.read_bytes() == Fixture.original_source
            before, after = ('Built through Kiln AI.', 'Second retained version.') if 'second' in prompt else ('Server-rendered.<br>Live by default.', 'Built through Kiln AI.')
            good = dict(module='dev/site', edits=json.dumps([dict(before=before, after=after)]))
            if 'Validation failed' in content:
                assert 'Compiler diagnostics' in content
                name, args = 'validate_web_source', good
            else:
                assert 'Isolated compile passed' in content and 'not changed' in content
                name, args = 'update_web_source', good
        else:
            raise AssertionError('Unexpected fixture tool phase')
        data = (json.dumps(dict(message=dict(role='assistant', content='', tool_calls=[dict(function=dict(name=name, arguments=args))]), done=True, done_reason='stop'))+'\n').encode()
        self.send_response(200); self.send_header('Content-Type', 'application/x-ndjson'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='kiln-web-development-') as td:
    root = Path(td).resolve(); state = root/'state'; state.mkdir(mode=0o700)
    source = root/'App.swift'; source.write_text((ROOT/'Sources/ExampleWeb/Web.swift').read_text()); source.chmod(0o600)
    sdk = root/'sdk.json'
    subprocess.run(['python3', str(ROOT/'scripts/export-web-sdk.py'), '--build-dir',str(BIN),'--output',str(sdk),'--snapshot-dir',str(root/'sdk-inputs')],check=True)
    Fixture.source_path = source
    Fixture.original_source = source.read_bytes()
    sshport, ingress, worker, alternate = [freeport() for _ in range(4)]
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
    threading.Thread(target=fixture.serve_forever,daemon=True).start()
    routes = '\n'.join([
        '        try router.on("GET", "/inspection-redirect") { _ in WebResponse(status: 302, body: Data(), headers: ["location": "http://127.0.0.1:' + str(fixture.server_port) + '/unexpected"]) }',
        '        try router.on("GET", "/inspection-large") { _ in WebResponse(contentType: "text/plain", body: Data(repeating: 65, count: 100000)) }',
    ])
    source.write_text(source.read_text().replace('        var router = WebRouter()', '        var router = WebRouter()\n' + routes))
    Fixture.original_source = source.read_bytes()

    (state/'ai.json').write_text(json.dumps(dict(baseURL=f'http://127.0.0.1:{fixture.server_port}',model='fixture',provider='ollama',profile='local',contextID='fixture')))
    key=root/'admin'; subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    log=(root/'runtime.log').open('w')
    env={k:v for k,v in os.environ.items() if k.lower() not in ['http_proxy','https_proxy','all_proxy']}
    runtime=subprocess.Popen([str(BIN/'kiln'),'up','--state',str(state),'--authorized-keys',str(key)+'.pub','--host','127.0.0.1','--port',str(sshport)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,env=env)
    try:
        wait(lambda: (state/'ssh-host-ed25519.pub').exists())
        known=root/'known'; known.write_text(f'[127.0.0.1]:{sshport} '+(state/'ssh-host-ed25519.pub').read_text())
        base=['ssh','-F','/dev/null','-o','LogLevel=ERROR','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}','-i',str(key),'-p',str(sshport),'admin@127.0.0.1']
        def ssh(command,timeout=150):
            result=subprocess.run(base+[command],capture_output=True,text=True,timeout=timeout)
            assert result.returncode==0,(command,result.stdout,result.stderr)
            return result.stdout
        wait(lambda: subprocess.run(base+['status'],capture_output=True).returncode==0)
        manifest=root/'app.json'; origin=f'http://127.0.0.1:{ingress}'
        manifest.write_text(json.dumps(dict(application='dev',name='site',version='initial',executable=str(BIN/'kiln-example-web'),arguments=['--origin',origin,'--development'],healthURL=f'http://127.0.0.1:{worker}/__kiln/health',ingressPort=ingress)))
        ssh('app install '+str(manifest)); ssh('app start dev/site')
        def get(path):
            with urllib.request.urlopen(origin+path,timeout=5) as r:return r.read().decode()
        initial=json.loads(get('/__kiln/instance'))['instance']
        assert '/__kiln/development.js' in get('/')
        config=root/'project.json'; config.write_text(json.dumps(dict(schemaVersion=1,module='dev/site',source=str(source),sdk=str(sdk),publicOrigin=origin,ingressPort=ingress,workerPorts=[worker,alternate],autoPublish=True)))
        ssh('web register '+str(config))
        result=ssh('ai ask Change the heading for the dev/site development app')
        assert 'Published development change' in result and 'HTTP root inspection' in result,result
        assert 'Built through Kiln AI.' in source.read_text()
        assert 'Built through Kiln AI.' in get('/counter')
        assert json.loads(get('/__kiln/instance'))['instance'] != initial
        assert 'active' in ssh('web changes dev/site')
        print('PASS: real SSH / tool discovery / framework guide / paginated source / failed validation + repaired compile / healthy deploy / HTTP inspection / source saved / worker changed',flush=True)
        assert 'validated' in ssh('web changes dev/site')
        preview=json.loads(ssh('web preview dev/site /counter'))
        assert preview['status']==200 and 'Built through Kiln AI.' in preview['bodyPreview']
        redirect=json.loads(ssh('web preview dev/site /inspection-redirect'))
        assert redirect['status']==302 and Fixture.redirect_requests==0
        oversized=json.loads(ssh('web preview dev/site /inspection-large'))
        assert oversized['status']==200 and oversized['truncated'] and len(oversized['bodyPreview'])==2500
        print('PASS: preview inspection bounds output, blocks redirects and rejects host/path escape',flush=True)
        for unsafe in ['//example.invalid/' , '/%2e%2e/private', '/x?token=y', '/x#fragment', 'http://127.0.0.1/']:
            denied=subprocess.run(base+['web preview dev/site '+unsafe],capture_output=True,text=True)
            assert denied.returncode!=0,unsafe
        history=json.loads(ssh('web history dev/site'))
        first=next(row for row in history if row['status']=='active')
        assert len(first['commit'])==40
        diff=ssh('web diff dev/site '+first['id'])
        assert '+        <h1>Built through Kiln AI.' in diff or ('+<h1>' in diff or 'Built through Kiln AI.' in diff)
        retained_code=ssh('web code dev/site '+first['id'])
        assert 'complete retained source' in retained_code
        code_lines=retained_code.split('File App.swift / complete retained source\n',1)[1].removesuffix('\n').split('\n')
        assert all(line[8:]==original for line,original in zip(code_lines,source.read_text().split('\n')))
        assert len(code_lines)==len(source.read_text().split('\n'))
        Fixture.original_source=source.read_bytes()
        second=ssh('ai ask Make a second development version')
        assert 'Published development change' in second and 'Second retained version.' in source.read_text(),second
        previous=source.read_bytes()
        assert ssh('web code dev/site '+first['id'])==retained_code
        assert source.read_bytes()==previous
        print('PASS: full line-numbered retained code includes unchanged lines and remains stable after a new release',flush=True)
        rollback=ssh('app rollback dev/site')
        assert 'Source-aware rollback' in rollback and 'Built through Kiln AI.' in get('/counter')
        assert source.read_bytes()==Fixture.original_source
        ssh('app rollback dev/site')
        assert source.read_bytes()==previous and 'Second retained version.' in get('/counter')
        restored=ssh('web restore dev/site '+first['id'])
        assert 'Published development change' in restored and source.read_bytes()==Fixture.original_source
        assert 'Built through Kiln AI.' in get('/counter')
        source.write_bytes(Fixture.original_source+b'\n// uncommitted local change\n')
        denied=subprocess.run(base+['app rollback dev/site'],capture_output=True,text=True)
        assert denied.returncode!=0 and 'Source changed independently' in denied.stdout
        assert source.read_bytes().endswith(b'// uncommitted local change\n')
        source.write_bytes(Fixture.original_source)
        history=json.loads(ssh('web history dev/site'))
        assert len([row for row in history if row['status']=='active'])==5
        assert next(row for row in history if row['id']==first['id'])['commit']==first['commit']
        print('PASS: Git-linked history + source diff / source-and-release rollback both ways / older version restored as a new release / local edits protected',flush=True)
        before=source.read_bytes(); release=ssh('app list'); instance=json.loads(get('/__kiln/instance'))['instance']
        broken=ssh('ai ask Make a broken development edit')
        assert 'before deployment' in broken and 'Compiler diagnostics' in broken,broken
        assert source.read_bytes()==before and ssh('app list')==release
        assert json.loads(get('/__kiln/instance'))['instance']==instance
        print('PASS: invalid Swift returns bounded diagnostics; live release, source and worker stay unchanged',flush=True)
        # Scope and SDK change are denied before arbitrary source or stale build input runs.
        denied=subprocess.run(base+['web source other/site'],capture_output=True,text=True)
        assert denied.returncode!=0
        sdk_input=next(Path(p) for p in json.loads(sdk.read_text())['inputDigests'] if p.endswith('/kiln-web-builder'))
        # Do not mutate SDK binaries shared with the checkout; corrupt registered
        # digest in a newly exported admin recipe and ensure registration rejects it.
        bad=json.loads(sdk.read_text()); bad['inputDigests'][str(sdk_input)]='0'*64
        sdk.write_text(json.dumps(bad))
        denied=subprocess.run(base+['web register '+str(config)],capture_output=True,text=True)
        assert denied.returncode!=0 and 'Trusted SDK changed' in denied.stdout
        print('PASS: unregistered module read and changed trusted SDK are denied',flush=True)
        # Explicitly opt in a dedicated project directory, separate from the SDK/config.
        workspace=root/'Project'; workspace.mkdir(mode=0o700)
        (workspace/'App.swift').write_bytes(source.read_bytes()); (workspace/'App.swift').chmod(0o600)
        original_sdk=bad; original_sdk['inputDigests'][str(sdk_input)]=hashlib.sha256(sdk_input.read_bytes()).hexdigest(); sdk.write_text(json.dumps(original_sdk))
        settings=json.loads(config.read_text()); settings.update(root=str(workspace),source=str(workspace/'App.swift')); config.write_text(json.dumps(settings))
        ssh('web register '+str(config)); source=workspace/'App.swift'; Fixture.source_path=source
        created=ssh('ai ask Create a component for the heading')
        assert 'Published development change' in created,created
        assert (workspace/'Components/Heading.swift').is_file() and 'Multi-file published.' in get('/counter')
        multi_history=json.loads(ssh('web history dev/site')); multi=next(r for r in multi_history if r['current']=='yes')
        multi_diff=ssh('web diff dev/site '+multi['id'])
        assert 'Components/Heading.swift' in multi_diff and '+func projectHeading' in multi_diff
        browse=json.loads(ssh('web browse dev/site Components/Heading.swift'))
        assert browse['tree']['projectRoot'] and browse['file']['source'].startswith('import Foundation')
        deleted=ssh('ai ask Delete the heading component and inline its old heading')
        assert 'Published development change' in deleted,deleted
        assert not (workspace/'Components/Heading.swift').exists() and 'Built through Kiln AI.' in get('/counter')
        ssh('app rollback dev/site')
        assert (workspace/'Components/Heading.swift').is_file() and 'Multi-file published.' in get('/counter')
        ssh('app rollback dev/site')
        assert not (workspace/'Components/Heading.swift').exists() and 'Built through Kiln AI.' in get('/counter')
        retained=json.loads(ssh('web browse dev/site Components/Heading.swift '+multi['id']))
        assert not retained['tree']['editable'] and 'Multi-file published.' in retained['file']['source']
        print('PASS: AI lists/reads files, creates and deletes nested Swift component, compiles all files, publishes live HTML, whole-project rollback both ways and retained read-only tree',flush=True)
        # The code-view Refactor command pins the displayed source and narrows
        # the AI turn to registered-project tools. Compile real actor extensions.
        entry=source.read_text(); sha=hashlib.sha256(source.read_bytes()).hexdigest()
        method='    func snapshot() -> (Int, String) { (count, note) }\n'
        Fixture.refactor_operations=[dict(path='App.swift',before=method,after=''),
            dict(path='App.swift',before='private var count = 0',after='var count = 0'),
            dict(path='App.swift',before='private var note =',after='var note ='),
            dict(path='Models/CounterModel+snapshot.swift',action='create',content='import Foundation\nextension CounterModel {\n'+method+'}\n')]
        stale=subprocess.run(base+['web refactor dev/site App.swift '+'0'*64+' functions'],capture_output=True,text=True)
        assert stale.returncode!=0 and source.read_text()==entry
        css_before=get('/assets/app.css')
        refactored=ssh('web refactor dev/site App.swift '+sha+' functions')
        assert 'Published development change' in refactored,refactored
        assert (workspace/'Models/CounterModel+snapshot.swift').is_file()
        assert method not in source.read_text() and 'Built through Kiln AI.' in get('/counter')
        assert get('/assets/app.css')==css_before
        history=json.loads(ssh('web history dev/site')); current=next(r for r in history if r['current']=='yes')
        assert 'CounterModel+snapshot.swift' in ssh('web diff dev/site '+current['id'])
        ssh('app rollback dev/site')
        assert source.read_text()==entry and not (workspace/'Models/CounterModel+snapshot.swift').exists()
        print('PASS: displayed-hash refactor guard / restricted AI tools / method extracted into Swift actor extension / isolated validation and publish / same HTML and CSS / whole-refactor rollback',flush=True)


    finally:
        if runtime.poll() is None:runtime.terminate();runtime.wait(timeout=20)
        subprocess.run([str(BIN/'kiln'),'session-service-stop','--state',str(state)],capture_output=True,timeout=15)
        fixture.shutdown(); log.close()
