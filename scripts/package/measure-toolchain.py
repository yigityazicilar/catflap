#!/usr/bin/env python3
"""Compare build-system and relocation controls on one pristine Ubuntu image."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

from run import APT_BUILD, ROOT

archive = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
if any(out.iterdir()):
    raise RuntimeError('Use an empty measurement directory')
with archive.open('rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
assert digest == json.loads((ROOT/'scripts/package/toolchains.json').read_text())['ubuntu']['sha256']
uid, gid = os.getuid(), os.getgid()
unique = 'catflap-compiler-controls-'+uuid.uuid4().hex[:10]
image = unique+':build'
with tempfile.TemporaryDirectory(prefix=unique+'-') as temporary:
    dockerfile = Path(temporary)/'Dockerfile'
    dockerfile.write_text('FROM ubuntu:26.04\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y '+APT_BUILD+'\n')
    try:
        subprocess.run(['docker', 'build', '--force-rm', '-t', image, str(dockerfile.parent)], env=dict(os.environ, DOCKER_BUILDKIT='0'), check=True)
        # Each arm starts from the exact same pristine build image. In particular,
        # the /usr control cannot contaminate the following real-path control.
        for name, prefix, strip in [('opt', '/opt/swift', '2'), ('usr', '/usr', '1'), ('real-path', '/work/toolchain-real', '2')]:
            target = '/' if name == 'usr' else prefix
            command = (
                "set -euo pipefail; trap 'chown -R "+str(uid)+':'+str(gid)+" /out' EXIT; "
                'mkdir -p '+prefix+' /work/home /work/tmp; '
                'export HOME=/work/home TMPDIR=/work/tmp; '
                'tar -xzf /archive.tar.gz -C '+target+' --strip-components='+strip+'; '
                'echo ARM_'+name+'; readlink -f '+prefix+'; '
                'PATH='+prefix+'/bin:/usr/bin:/bin python3 /probe.py /out/'+name
            )
            subprocess.run(['docker', 'run', '--rm', '--name', unique+'-'+name,
                            '-v', str(archive)+':/archive.tar.gz:ro',
                            '-v', str(ROOT/'scripts/package/probe-toolchain.py')+':/probe.py:ro',
                            '-v', str(out)+':/out', image, 'bash', '-c', command], check=True)
    finally:
        if subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(['docker', 'image', 'rm', image], check=True)
