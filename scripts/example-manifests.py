#!/usr/bin/env python3
"""Create local manifests for independent REST and WebSocket modules."""
import argparse, json, pathlib
root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--executable', type=pathlib.Path, default=root/'.build/debug/kiln-example-backend')
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
for name, port, flags in [('rest',18080,[]), ('websocket',18081,['--websocket'])]:
    manifest = dict(application='storefront',name=name,version='0.1.0',executable=str(a.executable.resolve()),arguments=['--port',str(port)]+flags,healthURL=f'http://127.0.0.1:{port}/health')
    path = a.output/f'{name}.json'
    path.write_text(json.dumps(manifest, indent=2)+'\n')
    print(path.resolve())
