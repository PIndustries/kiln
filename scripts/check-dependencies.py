#!/usr/bin/env python3
"""Offline dependency policy check. Does not download, resolve or run packages."""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
policy = json.loads((root / 'config/dependency-policy.json').read_text())
pins = json.loads((root / 'Package.resolved').read_text())['pins']
direct = sorted(re.findall(r'\.package\(url: "([^"]+)"', (root / 'Package.swift').read_text()))
actual = sorted([dict(identity=p['identity'], location=p['location'],
                      revision=p['state']['revision'], version=p['state'].get('version'))
                 for p in pins], key=lambda p: p['identity'])
errors = []
if policy['schemaVersion'] != 1:
    errors.append('Unknown dependency policy schema')
if direct != policy['directSources']:
    errors.append('Direct package sources changed; review and update dependency-policy.json deliberately')
if actual != policy['pins']:
    errors.append('Resolved package identities, sources or revisions changed outside the reviewed policy')
if len({p['identity'] for p in actual}) != len(actual):
    errors.append('Duplicate resolved package identity')
for p in actual:
    if not re.fullmatch(r'[0-9a-f]{40}', p['revision']):
        errors.append('Unpinned dependency: ' + p['identity'])
if errors:
    for error in errors:
        print('FAIL: ' + error, file=sys.stderr)
    sys.exit(1)
print(f'PASS: {len(direct)} direct sources and {len(actual)} resolved revisions match Kiln dependency policy. No network used.')
for p in actual:
    print(f"  {p['identity']} {p['version']} {p['revision'][:12]}")
