#!/usr/bin/env python3
"""Export an explicit trusted, already-built KilnWeb SDK; never runs package code.
Run swift build for kiln-example-web, kiln-web-builder and kiln-web-runtime first.
"""
import argparse
import hashlib
import json
import shlex
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--snapshot-dir', type=Path, help='Create a new immutable SDK input directory, independent of later checkout builds')
args = parser.parse_args()
base = args.build_dir.resolve()
plan = json.loads((base / 'description.json').read_text())
command = next(value for key, value in plan['swiftCommands'].items() if key.startswith('C.ExampleWeb-'))
objects = [path for path in shlex.split((base / 'kiln-example-web.product/Objects.LinkFileList').read_text()) if '/ExampleWeb.build/' not in path]
compiler = Path(command['executable'])
arguments = ['-module-name', 'ExampleWeb', '-parse-as-library', '-swift-version', '6', '-I', command['importPath']]
original = iter(command['otherArguments'])
for flag in original:
    if flag in ['-target', '-sdk', '-F', '-I', '-L', '-package-name', '-Xcc']:
        arguments += [flag, next(original)]
    elif flag in ['-index-store-path', '-module-cache-path', '-plugin-path', '-Xfrontend']:
        next(original)
# Runtimes introduced by this toolchain may be loaded from its compatibility dir.
libraries = [str(compiler.parent.parent / 'lib/swift')]
arguments += ['-Xlinker', '-rpath', '-Xlinker', libraries[0] + '/macosx']
read_roots = [str(base.parent.parent.resolve()), str(compiler.parent.parent.parent)]
for value in [str(compiler)] + arguments:
    if '/Contents/Developer/' in value:
        root = value.split('/Contents/Developer/')[0] + '/Contents'
        if root not in read_roots:
            read_roots.append(root)
# Standalone Swift toolchains need Xcode's actual linker, not the /usr/bin
# xcrun shim (which requires developer-selection IPC inside the sandbox).
linkers = [Path(root) / 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld'
           for root in read_roots if root.endswith('/Contents')]
linker = next((path for path in linkers if path.is_file()), None)
assert linker is not None, 'No trusted Xcode linker found in the SDK roots'
arguments += ['-ld-path=' + str(linker)]
inputs = set(objects) | {str(base / 'kiln-web-builder'), str(base / 'kiln-web-runtime')}
for object_path in objects:
    name = Path(object_path).parent.name.removesuffix('.build')
    module = base / 'Modules' / (name + '.swiftmodule')
    if module.is_file():
        inputs.add(str(module))
builder, launcher = str(base / 'kiln-web-builder'), str(base / 'kiln-web-runtime')
if args.snapshot_dir:
    build_root = base.parent.parent.resolve()
    snapshot = args.snapshot_dir.resolve()
    snapshot.mkdir(mode=0o700, parents=True, exist_ok=False)
    inputs |= {str(p.resolve()) for p in build_root.rglob('*') if p.is_file() and (p.suffix in ['.h', '.hpp'] or p.name == 'module.modulemap')}
    for path in sorted(inputs):
        original = Path(path)
        destination = snapshot / original.relative_to(build_root)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if original.name == 'module.modulemap':
            destination.write_bytes(original.read_bytes().replace(str(build_root).encode(), str(snapshot).encode()))
        else:
            shutil.copy2(original, destination)
        destination.chmod(0o700 if path in [builder, launcher] else 0o600)
    def remap(value): return value.replace(str(build_root), str(snapshot))
    arguments = [remap(v) for v in arguments]
    objects = [remap(v) for v in objects]
    inputs = {remap(v) for v in inputs}
    read_roots = [remap(v) for v in read_roots]
    builder, launcher = remap(builder), remap(launcher)
# Use the installed toolchain's test flags, never a project package or plugin.
test_command = next((v for k, v in plan['swiftCommands'].items() if k.startswith('C.KilnTests-')), command)
testing_arguments = []
testing_roots = []
flags = iter(test_command['otherArguments'])
for flag in flags:
    if flag == '-Xcc':
        next(flags)
        continue
    if flag in ['-plugin-path', '-F', '-I', '-L']:
        path = next(flags)
        if flag == '-plugin-path' or (flag, path) not in zip(arguments, arguments[1:]):
            testing_arguments += [flag, path]
        if flag in ['-F', '-L'] and path not in testing_roots:
            testing_roots.append(path)
        if flag == '-F':
            binary = Path(path) / 'Testing.framework/Testing'
            if binary.is_file():
                inputs.add(str(binary.resolve()))
                testing_arguments += ['-Xlinker', '-rpath', '-Xlinker', path]
plugin = compiler.parent.parent / 'lib/swift/host/plugins/testing'
if plugin.is_dir() and '-plugin-path' not in testing_arguments:
    testing_arguments += ['-plugin-path', str(plugin)]
if plugin.is_dir():
    inputs |= {str(p.resolve()) for p in plugin.rglob('*') if p.is_file()}
# Test-only flags may point at build modules; preserve immutable SDK remapping.
if args.snapshot_dir:
    testing_arguments = [remap(v) for v in testing_arguments]
    testing_roots = [remap(v) for v in testing_roots]
metadata = dict(testArguments=testing_arguments, testReadRoots=testing_roots, nativeViews=True, htmlTemplates=True, schemaVersion=1, projectFiles=True, compiler=str(compiler), arguments=arguments, objects=objects,
                readRoots=read_roots, runtimeLibraries=libraries, builder=builder, launcher=launcher,
                inputDigests={path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in sorted(inputs)})
for name in ['builder', 'launcher']:
    assert Path(metadata[name]).is_file(), f'Build {metadata[name]} first'
args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
args.output.write_text(json.dumps(metadata, indent=2) + '\n')
args.output.chmod(0o600)
print(f'Trusted web SDK exported: {len(objects)} objects, {len(inputs)} pinned inputs')
