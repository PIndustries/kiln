#!/usr/bin/env python3
"""Private native-view/template MVC build and HTTP acceptance; no providers."""
import base64
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('KILN_BIN_DIR') or subprocess.check_output(['swift','build','--build-system','native','--show-bin-path'],cwd=ROOT,text=True).strip()).resolve()
with tempfile.TemporaryDirectory(prefix='kiln-native-mvc-') as td:
    root = Path(td).resolve()
    sdkfile = root/'sdk.json'
    subprocess.run(['python3',str(ROOT/'scripts/export-web-sdk.py'),'--build-dir',str(BIN),'--snapshot-dir',str(root/'sdk-inputs'),'--output',str(sdkfile)],check=True)
    sdk = json.loads(sdkfile.read_text())
    assert sdk['nativeViews'] and sdk['htmlTemplates']
    job = root/'job'; job.mkdir(mode=0o700)
    source = ROOT/'examples/native-mvc'
    files = {str(p.relative_to(source)):p.read_bytes() for p in source.rglob('*') if p.is_file()}
    (job/'Files.json').write_text(json.dumps({p:base64.b64encode(data).decode() for p,data in files.items()}))
    shutil.copyfile(sdkfile,job/'sdk.json')
    for name,data in files.items():
        target = job/'Sources'/name; target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(data)
    build = subprocess.run([sdk['builder'],str(job)],capture_output=True,text=True,timeout=90)
    assert build.returncode == 0,build.stdout+build.stderr
    # Generated template API participates in a real SourceKit compilation database.
    subprocess.run(['swift','test','--build-system','native','--skip-build','--filter','nativeViewsAndHTMLTemplatesCompileTogetherAndHaveLanguageServiceSupport'],cwd=ROOT,env={**os.environ,'KILN_MVC_SDK':str(sdkfile)},check=True,timeout=120)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
    origin = f'http://127.0.0.1:{port}'; data = root/'data'; data.mkdir()
    binary = job/'app'
    with (root/'server.log').open('w') as log:
        process = subprocess.Popen([sdk['launcher'],str(binary),hashlib.sha256(binary.read_bytes()).hexdigest(),json.dumps(sdk['runtimeLibraries']),'--origin',origin,'--development'],env={**os.environ,'KILN_PORT':str(port),'KILN_DATA_DIR':str(data)},stdout=log,stderr=log)
        try:
            cookies = http.cookiejar.CookieJar(); client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
            deadline = time.monotonic()+20
            while True:
                try:
                    with client.open(origin+'/',timeout=2) as response:
                        home = response.read().decode()
                        assert response.headers.get('Referrer-Policy') == 'same-origin'
                    break
                except (OSError,urllib.error.URLError):
                    assert time.monotonic()<deadline,'MVC sample server failed to start'
                    time.sleep(.1)
            assert 'Hello from P.Industries' in home and 'sidenav' in home
            stylepath = re.search(r'href="(/__kiln/style/[^"]+)"',home).group(1)
            with client.open(origin+stylepath) as response:
                assert response.headers.get_content_type() == 'text/css'
                assert 'scroll-margin-top:24px' in response.read().decode()
            forged = stylepath.replace('.css','a.css')
            try: client.open(origin+forged); raise AssertionError('Unsigned CSS was accepted')
            except urllib.error.HTTPError as error: assert error.code == 404
            token = re.search(r'name="_csrf"[^>]*value="([^"]+)"',home).group(1)
            form = urllib.parse.urlencode({'_csrf':token,'name':'<b>A&B</b>'}).encode()
            request = urllib.request.Request(origin+'/greet',data=form,headers={'Origin':origin,'Content-Type':'application/x-www-form-urlencoded'})
            with client.open(request) as response: greeting = response.read().decode()
            assert 'Hello, &lt;b&gt;A&amp;B&lt;/b&gt;' in greeting and '<b>A&B</b>' not in greeting
            assert 'class="shell"' in greeting # HTML template inside a native Swift layout.
            with client.open(origin+'/counter') as response: counter = response.read().decode()
            assert '<strong id="count">0</strong>' in counter and 'data-kiln-click="increment"' in counter
            assert 'data-kiln-submit="rename"' in counter and 'data-development-reload="true"' in counter
            with client.open(origin+'/assets/app.css') as response: css = response.read().decode()
            assert '--accent:' in css and '--bg:' in css and 'color:var(--accent)' in css
            bad = urllib.request.Request(origin+'/greet',data=b'name=unauthorized',headers={'Origin':origin,'Content-Type':'application/x-www-form-urlencoded'})
            try: client.open(bad); raise AssertionError('CSRF was bypassed')
            except urllib.error.HTTPError as error: assert error.code == 403
            print('PASS: real isolated MVC example; native Swift views; HTML template with escaped data inside native layout; preserved CSS variables; live event/reload markup; CSRF rejection; generated API SourceKit completion. No provider traffic.')
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
