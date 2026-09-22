#!/usr/bin/env python3
"""Reconstruct the release's patched OpenMW tree from its bundled source, without a Git clone."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = Path(args.output).resolve()
if output.exists():
    raise SystemExit('Output must not already exist.')
materialization = json.loads((root / 'manifests/openmw-source-materialization.json').read_text())
pin = json.loads((root / 'config/source-pins/openmw.json').read_text())
manifest = json.loads((root / 'openmw-patches/patch-manifest.json').read_text())
archive = (root / materialization['archive']).resolve()
if root not in archive.parents or materialization['upstream']['commit'] != pin['commit'] or manifest['upstream']['commit'] != pin['commit']:
    raise SystemExit('Source archive path or pin mismatch.')
if hashlib.sha256(archive.read_bytes()).hexdigest() != materialization['sha256']:
    raise SystemExit('Source archive checksum mismatch.')
with tarfile.open(archive) as source:
    # Only plain source files/directories, never links or archive paths outside the new tree.
    for item in source.getmembers():
        target = (output / item.name).resolve()
        if output not in target.parents or not (item.isfile() or item.isdir()):
            raise SystemExit('Unsafe source archive entry: ' + item.name)
    output.mkdir(parents=True)
    source.extractall(output, filter='data')
for change in manifest['changes']:
    target = (output / change['path']).resolve()
    artifact = (root / 'openmw-patches' / change['artifact']).resolve()
    if output not in target.parents or (root / 'openmw-patches') not in artifact.parents:
        raise SystemExit('Unsafe patch path.')
    if hashlib.sha256(artifact.read_bytes()).hexdigest() != change['artifact_sha256']:
        raise SystemExit('Patch checksum mismatch: ' + change['path'])
    before = target.read_bytes() if target.is_file() else None
    blob = hashlib.sha1(b'blob ' + str(len(before)).encode() + b'\0' + before).hexdigest() if before is not None else None
    if blob != change['base_blob']:
        raise SystemExit('Base source mismatch: ' + change['path'])
    if change['operation'] == 'add':
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact, target)
    else:
        subprocess.run(['git', 'apply', '--whitespace=nowarn', str(artifact)], cwd=output, check=True)
    if change['operation'] != 'delete' and hashlib.sha256(target.read_bytes()).hexdigest() != change['result_sha256']:
        raise SystemExit('Patched source mismatch: ' + change['path'])
print('Verified patched OpenMW source:', output)
