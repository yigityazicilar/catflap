#!/usr/bin/env python3
"""Package JavaScript unchanged and compile the extension's GSettings schema."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--install', type=Path)
args = parser.parse_args()
metadata = json.loads((args.source / 'metadata.json').read_text())
uuid = metadata['uuid']
assert uuid == 'catflap@yigityazicilar.github.io'
schema = 'org.gnome.shell.extensions.catflap.gschema.xml'
files = {name: (args.source / name).read_bytes() for name in
         ('metadata.json', 'extension.js', 'catflap-symbolic.svg', 'schemas/' + schema)}
args.output.mkdir(parents=True, exist_ok=True)
# Shell's getSettings loads a compiled cache, never XML directly. Keep build output
# outside the source tree so container and host toolchains cannot dirty each other.
with tempfile.TemporaryDirectory(prefix='.catflap-schema-', dir=args.output) as temporary:
    schemas = Path(temporary) / 'schemas'
    schemas.mkdir()
    (schemas / schema).write_bytes(files['schemas/' + schema])
    subprocess.run(['glib-compile-schemas', '--strict', str(schemas)], check=True)
    files['schemas/gschemas.compiled'] = (schemas / 'gschemas.compiled').read_bytes()
archive = args.output / (uuid + '.zip')
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
    for name, content in files.items():
        entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        entry.external_attr = 0o100644 << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        package.writestr(entry, content)
if args.install:
    target = args.install / uuid
    if target.is_symlink():
        raise RuntimeError('Refusing a linked extension directory')
    target.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        destination = target / name
        if destination.is_symlink() or destination.parent.is_symlink():
            raise RuntimeError('Refusing a linked extension file or directory')
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        destination.chmod(0o644)
print(archive)
