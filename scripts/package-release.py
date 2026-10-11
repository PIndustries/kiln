#!/usr/bin/env python3
"""Build a clean revision and package only declared public distribution files."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='Directory outside the source checkout')
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('output must be outside the source checkout')
    if run('git', 'status', '--porcelain', '--untracked-files=all'):
        parser.error('package builds require a clean checkout')
    compiler = run('swift', '--version')
    if not re.search(r'Swift version 6\.2\.3(?:\s|$)', compiler):
        parser.error('Swift 6.2.3 is required')
    system, machine = platform.system(), platform.machine()
    targets = {('Darwin', 'arm64'): 'macos-arm64', ('Linux', 'x86_64'): 'linux-x86_64'}
    if (system, machine) not in targets:
        parser.error('supported package hosts: Apple Silicon macOS or Linux x86_64')
    revision = run('git', 'rev-parse', 'HEAD')
    epoch = int(run('git', 'show', '-s', '--format=%ct', 'HEAD'))
    subprocess.run(['swift', 'build', '-c', 'release', '--jobs', '2', '--force-resolved-versions'], cwd=ROOT, check=True)
    binary_dir = Path(run('swift', 'build', '-c', 'release', '--show-bin-path'))
    version = run(str(binary_dir / 'kiln'), '--version')
    if not re.fullmatch(r'\d{2}\.\d{2}\.\d{2}\.[1-9]\d*', version):
        raise SystemExit('runtime returned an invalid release identifier')
    name = f'kiln-{version}-{targets[(system, machine)]}'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='kiln-package-') as temporary:
        stage = Path(temporary) / name
        (stage / 'bin').mkdir(parents=True)
        for executable in ('kiln', 'kiln-example-backend'):
            shutil.copy2(binary_dir / executable, stage / 'bin' / executable)
        for filename in ('LICENSE', 'THIRD-PARTY-NOTICES.txt', 'README.md', 'Package.resolved'):
            shutil.copy2(ROOT / filename, stage / filename)
        shutil.copytree(ROOT / 'docs', stage / 'docs')
        (stage / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/example-manifests.py', stage / 'scripts/example-manifests.py')
        dependencies = {}
        for executable in sorted((stage / 'bin').iterdir()):
            command = ['otool', '-L', str(executable)] if system == 'Darwin' else ['ldd', str(executable)]
            dependencies[executable.name] = run(*command).replace(str(stage), '<package>')
        manifest = {
            'version': version, 'sourceRevision': revision, 'platform': targets[(system, machine)],
            'compiler': compiler, 'packageResolvedSHA256': digest(ROOT / 'Package.resolved'),
            'runtimeRequirements': 'macOS 14 or later' if system == 'Darwin' else 'Swift 6.2.3 runtime and matching distribution libraries; see docs/packages.md',
            'dynamicDependencies': dependencies,
            'files': {str(p.relative_to(stage)): digest(p) for p in sorted(stage.rglob('*')) if p.is_file()},
        }
        (stage / 'build-info.json').write_text(json.dumps(manifest, indent=2) + '\n')
        archive = output / (name + '.tar.gz')
        # Stable archive metadata. Compiler output is not claimed to be bit-for-bit reproducible.
        import gzip
        with archive.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as zipped, tarfile.open(fileobj=zipped, mode='w') as tar:
            for path in [stage, *sorted(stage.rglob('*'))]:
                info = tar.gettarinfo(str(path), arcname=str(path.relative_to(stage.parent)))
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mtime = epoch
                if path.is_file():
                    with path.open('rb') as source:
                        tar.addfile(info, source)
                else:
                    tar.addfile(info)
        checksum = archive.with_suffix(archive.suffix + '.sha256')
        checksum.write_text(f'{digest(archive)}  {archive.name}\n')
        print(archive)
        print(checksum)

if __name__ == '__main__':
    main()
