#!/usr/bin/env python3
"""Install the exact scanner binary from a SHA-256-verified upstream archive."""
import argparse
import hashlib
import pathlib
import platform
import tarfile
import tempfile
import urllib.request

VERSION = '8.30.1'
DIGESTS = {
    ('Linux', 'x86_64'): ('linux_x64', '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'),
    ('Darwin', 'arm64'): ('darwin_arm64', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'),
    ('Darwin', 'x86_64'): ('darwin_x64', 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', type=pathlib.Path, required=True)
args = parser.parse_args()
flavor, digest = DIGESTS[(platform.system(), platform.machine())]
url = f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{flavor}.tar.gz'
with tempfile.TemporaryDirectory(prefix='kiln-scanner-install-') as temporary:
    archive = pathlib.Path(temporary) / 'gitleaks.tar.gz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive.write_bytes(response.read(32 * 1024 * 1024))
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise SystemExit('Scanner archive checksum mismatch')
    with tarfile.open(archive, 'r:gz') as package:
        member = package.getmember('gitleaks')
        if not member.isfile():
            raise SystemExit('Expected regular scanner executable')
        args.directory.mkdir(parents=True, exist_ok=True)
        destination = args.directory / 'gitleaks'
        destination.write_bytes(package.extractfile(member).read())
        destination.chmod(0o755)
print(f'Installed Gitleaks {VERSION} to {args.directory}')
