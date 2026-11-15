#!/usr/bin/env python3
"""Compare SwiftPM compiler discovery before applying package compiler selection."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
swift = shutil.which('swift')
if swift is None:
    raise RuntimeError('Swift toolchain is not on PATH')
bin_dir = Path(swift).parent
with tempfile.TemporaryDirectory(prefix='catflap-compiler-discovery-') as tmp:
    root = Path(tmp)
    (root/'Sources/Probe').mkdir(parents=True)
    (root/'Package.swift').write_text('// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")])\n')
    (root/'Sources/Probe/main.swift').write_text('print("compiler discovery probe")\n')
    base = dict(os.environ)
    base.pop('SWIFT_EXEC', None)
    cases = [
        ('driver', ['swift', 'build', '-v'], base),
        ('direct', [str(bin_dir/'swift-build'), '-v'], base),
        ('explicit', ['swift', 'build', '-v'], dict(base, SWIFT_EXEC=str(bin_dir/'swiftc'))),
        ('native', ['swift', 'build', '-v', '--build-system', 'native'], base),
    ]
    for name, command, env in cases:
        if (root/'.build').exists():
            shutil.rmtree(root/'.build')
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=180)
        text = result.stdout + result.stderr
        (out/('compiler-discovery-'+name+'.log')).write_text(text)
        compiler = str(bin_dir/'swiftc')
        print('Compiler discovery:', name, 'command='+str(command), 'exit='+str(result.returncode), 'names_toolchain_swiftc='+str(compiler in text), flush=True)
        errors = [line for line in text.splitlines() if 'not an executable file' in line]
        if errors:
            print(errors[0], flush=True)
        if name == 'native':
            assert result.returncode == 0, text[-3000:]
            assert compiler in text, 'Expected compiler path absent from verbose build output'
