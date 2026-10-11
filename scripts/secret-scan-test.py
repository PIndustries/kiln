#!/usr/bin/env python3
"""Disposable synthetic canaries prove detection, narrow exclusions and redaction."""
import json
import pathlib
import secrets
import subprocess
import sys
import tarfile
import tempfile

SCAN = pathlib.Path(__file__).with_name('secret-scan.py')
with tempfile.TemporaryDirectory(prefix='kiln-scanner-test-') as temporary:
    root = pathlib.Path(temporary); inputs = root / 'inputs'; inputs.mkdir()
    output = root / 'reports'
    fixture = inputs / 'example.swift'
    swift_type = '.'.join(('Curve25519', 'Signing', 'PrivateKey'))
    fixture.write_text(f'let key: {swift_type}\nlet privateKey: {swift_type}\n')
    def run(expected):
        result = subprocess.run([sys.executable, str(SCAN), '--artifacts', str(inputs), '--output', str(output)], capture_output=True, text=True)
        assert result.returncode == expected, 'Unexpected scanner result (output withheld)'
        return result
    run(0)
    token = 'gh' + 'p_' + secrets.token_hex(18)
    # Inline suppression and artifact-provided ignores must not hide a canary.
    fixture.write_text(f'let key: {swift_type}\nlet token = "{token}" // gitleaks:allow\n')
    (inputs / '.gitleaksignore').write_text('*\n')
    result = run(1)
    report = (output / 'artifacts.json').read_text()
    assert token not in result.stdout + result.stderr + report, 'Synthetic value leaked'
    findings = json.loads(report)['findings']
    assert any(x['RuleID'] == 'github-pat' for x in findings), 'Canary not detected by credential rule'
    sensitive_name = inputs / token
    fixture.rename(sensitive_name)
    fixture = sensitive_name
    result = run(1)
    assert token not in result.stdout + result.stderr + (output / 'artifacts.json').read_text()
    archive = inputs / 'candidate.tar.gz'
    with tarfile.open(archive, 'w:gz') as package:
        package.add(fixture, arcname='bundle/' + token)
    fixture.unlink()
    result = run(1)
    assert token not in result.stdout + result.stderr + (output / 'artifacts.json').read_text()
print('PASS narrow declaration exclusion, synthetic credential detection, archive scanning and redacted reports')
