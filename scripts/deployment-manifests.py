#!/usr/bin/env python3
"""Generate two locally built, independently versioned demonstration releases."""
import argparse, json, pathlib
p = argparse.ArgumentParser()
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--executable', type=pathlib.Path, required=True)
p.add_argument('--ingress-port', type=int, default=18090)
p.add_argument('--worker-port', type=int, default=19090)
a = p.parse_args()
assert a.executable.is_file(), 'Build the example executable first'
a.output.mkdir(parents=True, exist_ok=True)
for version, worker in [('1.0.0', a.worker_port), ('1.1.0', a.worker_port+1)]:
    manifest = dict(application='release-demo', name='backend', version=version,
                    executable=str(a.executable.resolve()), arguments=['--websocket'],
                    healthURL=f'http://127.0.0.1:{worker}/health', ingressPort=a.ingress_port)
    path = a.output/f'{version}.json'
    path.write_text(json.dumps(manifest, indent=2)+'\n')
    print(path.resolve())
