#!/usr/bin/env python3
"""Opt-in paid inference acceptance. No keys on argv; use existing Vault grants."""
import argparse
import os
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--state', required=True, type=pathlib.Path)
parser.add_argument('--profile', default='default')
args = parser.parse_args()
if not args.state.is_dir():
    parser.error('state directory does not exist')
env = os.environ.copy()
env.update(KILN_PROVIDER_ACCEPTANCE='1', KILN_PROVIDER_STATE=str(args.state.resolve()), KILN_PROVIDER_PROFILE=args.profile)
result = subprocess.run(['swift', 'test', '--jobs', '2', '--filter', 'providerLiveAcceptance'],
                        cwd=pathlib.Path(__file__).resolve().parent.parent, env=env, capture_output=True, text=True)
# Swift compiler/test diagnostics can contain local paths; emit only fixed acceptance records.
records = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith('KILN_PROVIDER_ACCEPTANCE ')]
for line in records:
    print(line)
if result.returncode != 0 and not records:
    print('KILN_PROVIDER_ACCEPTANCE result=unavailable reason=build-or-configuration')
sys.exit(result.returncode)
