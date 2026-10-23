#!/usr/bin/env python3
"""Create a directory bundle from an explicitly selected payload tree.

The module manifest's executable is relative to --payload. This tool does not
compile, download dependencies, rewrite loader paths or execute install hooks.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import tempfile


def portable(path):
    parts = path.split("/")
    return (0 < len(path.encode()) <= 1024 and all(
        part not in ("", ".", "..") and len(part) <= 255 and re.fullmatch(r"[A-Za-z0-9_.-]+", part)
        for part in parts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--payload", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--platform", choices=["macos-arm64", "linux-x86_64"], required=True)
    args = parser.parse_args()
    if args.payload.is_symlink() or not args.payload.is_dir():
        parser.error("payload must be a real directory")
    payload, output = args.payload.resolve(), args.output.resolve()
    if output == payload or payload in output.parents or output.exists():
        parser.error("output must be new and outside the payload")
    module = json.loads(args.manifest.read_text())
    allowed = {"application", "name", "version", "executable", "arguments", "healthURL", "ingressPort", "secrets", "restartPolicy", "resources"}
    if not isinstance(module, dict) or not set(module) <= allowed:
        parser.error("unsupported application manifest fields")
    entry = module.get("executable", "")
    if not portable(entry):
        parser.error("executable must be a relative portable path inside the payload")
    sources = []
    prefixes = {}
    total = 0
    for path in sorted(payload.rglob("*")):
        relative = path.relative_to(payload).as_posix()
        if not portable(relative) or relative.split("/")[0].lower() == "bundle.json" or path.is_symlink():
            parser.error("invalid, reserved or symlink payload path: " + relative)
        if not path.is_dir() and not path.is_file():
            parser.error("payload contains a special file: " + relative)
        parts = relative.split("/")
        for count in range(1, len(parts) + 1):
            prefix = "/".join(parts[:count])
            if prefixes.get(prefix.lower(), prefix) != prefix:
                parser.error("case-insensitive payload path collision")
            prefixes[prefix.lower()] = prefix
        if path.is_file():
            size = path.stat().st_size
            total += size
            if size > 268435456 or total > 536870912:
                parser.error("payload exceeds 256 MiB/file or 512 MiB total")
            sources.append((path, relative))
    if not 1 <= len(sources) <= 4096:
        parser.error("payload requires 1–4096 regular files")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".kiln-bundle-", dir=output.parent) as temporary:
        stage = pathlib.Path(temporary) / "payload"
        stage.mkdir()
        files = []
        for source, relative in sources:
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            executable = bool(source.stat().st_mode & 0o111)
            destination.chmod(0o500 if executable else 0o400)
            with destination.open("rb") as handle:
                digest = hashlib.file_digest(handle, "sha256").hexdigest()
            files.append(dict(path=relative, sha256=digest, executable=executable))
        if not any(f["path"] == entry and f["executable"] for f in files):
            parser.error("entrypoint must be a payload file with executable permission")
        manifest = dict(formatVersion=1, platform=args.platform, module=module, files=files)
        encoded = json.dumps(manifest, sort_keys=True, indent=2) + "\n"
        if len(encoded.encode()) > 2097152:
            parser.error("bundle manifest exceeds 2 MiB")
        (stage / "bundle.json").write_text(encoded)
        stage.rename(output)
    print(output)


if __name__ == "__main__":
    main()
