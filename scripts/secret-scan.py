#!/usr/bin/env python3
"""Scan history, tracked working files, or release assets; emit metadata only."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '8.30.1'


def scan(mode, target, report, scratch):
    raw = scratch / (mode + '-raw.json')
    ignore = ROOT / '.gitleaksignore' if mode == 'history' else scratch / 'empty-ignore'
    (scratch / 'empty-ignore').touch()
    command = ['gitleaks', 'git' if mode == 'history' else 'dir', str(target),
               '--config', str(ROOT / '.gitleaks.toml'),
               '--gitleaks-ignore-path', str(ignore), '--ignore-gitleaks-allow',
               '--redact=100', '--no-banner', '--no-color', '--timeout', '180',
               '--max-archive-depth', '3', '--max-decode-depth', '5',
               '--report-format', 'json', '--report-path', str(raw)]
    if mode == 'history':
        command += ['--log-opts=--all']
    result = subprocess.run(command, capture_output=True, timeout=200)
    # Never echo scanner stdout/stderr or serialize matched text, even on failure.
    if result.returncode not in (0, 1) or not raw.exists():
        raise RuntimeError('Scanner failed; no clean result can be claimed')
    findings = json.loads(raw.read_text())
    if result.returncode == 1 and not findings:
        raise RuntimeError("Scanner failure did not produce findings")
    metadata = []
    for finding in findings:
        # Paths/fingerprints may themselves contain a secret supplied as a filename.
        # Public artifacts therefore carry hashes, never attacker-controlled names.
        path = str(finding.get('File', ''))
        relative = path.removeprefix(str(target).rstrip('/') + '/')
        metadata.append({field: finding.get(field) for field in
                         ('RuleID', 'StartLine', 'EndLine', 'Commit')} |
                        {'FileSHA256': hashlib.sha256(relative.encode()).hexdigest()})
    report.write_text(json.dumps({'scanner': VERSION, 'scope': mode,
                                 'findings': metadata}, indent=2) + '\n')
    print(f'{mode}: {len(findings)} finding(s); metadata-only report: {report}')
    return bool(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--tree', action='store_true')
    parser.add_argument('--artifacts', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not (args.history or args.tree or args.artifacts):
        parser.error('select at least one scope')
    version = subprocess.run(['gitleaks', 'version'], capture_output=True, text=True, check=True)
    if version.stdout.strip() != VERSION:
        raise RuntimeError('Expected pinned Gitleaks ' + VERSION)
    args.output.mkdir(parents=True, exist_ok=True)
    findings = False
    with tempfile.TemporaryDirectory(prefix='kiln-secret-scan-') as directory:
        scratch = pathlib.Path(directory)
        if args.history:
            shallow = subprocess.check_output(['git', 'rev-parse', '--is-shallow-repository'], cwd=ROOT, text=True).strip()
            if shallow != 'false':
                raise RuntimeError('Full history is required')
            findings |= scan('history', ROOT, args.output / 'history.json', scratch)
        if args.tree:
            tracked = scratch / 'tracked'; tracked.mkdir()
            paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).split(b'\0')
            for value in filter(None, paths):
                relative = pathlib.Path(os.fsdecode(value)); source = ROOT / relative
                if source.is_symlink():
                    raise RuntimeError('Tracked symlink requires explicit review before scanning')
                if source.is_file():
                    destination = tracked / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
            findings |= scan('tree', tracked, args.output / 'tree.json', scratch)
        if args.artifacts:
            if not args.artifacts.is_dir() or not any(args.artifacts.iterdir()):
                raise RuntimeError('Artifact directory missing or empty; nothing was verified')
            findings |= scan('artifacts', args.artifacts.resolve(), args.output / 'artifacts.json', scratch)
    return 1 if findings else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError):
        # Exception strings can contain attacker-controlled file paths or tool output.
        print('Secret scan could not complete. Check scanner version, scope and access; do not treat this as a clean scan.')
        raise SystemExit(2)
