#!/usr/bin/env python3
"""Build and install-test one distro in different disposable containers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    'ubuntu': ('ubuntu:26.04', 'deb'),
    'debian': ('debian:13', 'deb'),
    'fedora': ('fedora:45', 'rpm'),
    'arch': ('archlinux:latest', 'arch'),
}
APT_BUILD = 'build-essential clang git pkg-config libsqlite3-dev libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev libwayland-dev libx11-dev libxfixes-dev patchelf python3 libncurses6'
APT_RUNTIME = 'python3 libgtk-4-1 libadwaita-1-0 libgtk4-layer-shell0 libwayland-client0 libx11-6 libxfixes3 libsqlite3-0 libstdc++6 libgcc-s1 zlib1g'
FEDORA_BUILD = 'gcc gcc-c++ clang git pkgconf-pkg-config sqlite-devel gtk4-devel libadwaita-devel gtk4-layer-shell-devel wayland-devel libX11-devel libXfixes-devel patchelf python3 rpm-build ncurses-libs findutils diffutils libxml2_2.13'
ARCH_BUILD = 'base-devel clang go git pkgconf sqlite gtk4 libadwaita gtk4-layer-shell wayland libx11 libxfixes patchelf python ncurses libxml2-legacy util-linux-libs'
SWIFT_BIN_COMMIT = 'f78c5ec6f5be1052fa6ffd3bf78ee44b3fb607a0'

def run(args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(args, check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('target', choices=TARGETS)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolchain-archive', type=Path, help='Reuse a local archive; the pinned checksum is still required')
    args = parser.parse_args()
    base, kind = TARGETS[args.target]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError('Output directory must be empty: '+str(output))
    unique = 'catflap-package-'+args.target+'-'+uuid.uuid4().hex[:10]
    image = unique+':build'
    uid, gid = os.getuid(), os.getgid()
    if kind == 'deb':
        setup = 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y '+APT_BUILD
        runtime = 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y '+APT_RUNTIME+' && apt-get install -y /artifacts/*.deb'
    elif kind == 'rpm':
        setup = 'dnf install -y '+FEDORA_BUILD
        runtime = 'dnf install -y python3 /artifacts/*.rpm'
    else:
        setup = 'pacman -Syu --noconfirm '+ARCH_BUILD
        runtime = 'pacman -Syu --noconfirm python && pacman -U --noconfirm /artifacts/*.pkg.tar.zst'
    with tempfile.TemporaryDirectory(prefix=unique+'-') as temporary:
        work = Path(temporary)
        toolchain = json.loads((ROOT/'scripts/package/toolchains.json').read_text())[args.target]
        tool_archive = work / 'toolchain.tar.gz'
        if args.toolchain_archive:
            os.link(args.toolchain_archive.resolve(), tool_archive)
        else:
            run(['curl', '-fsSL', '--retry', '2', toolchain['url'], '-o', str(tool_archive)])
        with tool_archive.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        assert digest == toolchain['sha256'], 'Swift archive checksum mismatch'
        print('Signature-authenticated Swift 6.4.2 archive checksum:', digest, flush=True)
        user = str(uid)+':'+str(gid)
        if kind == 'arch':
            # Use the real pinned AUR repack recipe, including its native deps and
            # its ncurses ELF fixups. Never emulate that package in this driver.
            tool_setup = (
                'RUN git clone --no-checkout https://aur.archlinux.org/swift-bin.git /swift-bin && '
                'git -C /swift-bin checkout --detach '+SWIFT_BIN_COMMIT+'\n'
                'COPY toolchain.tar.gz /swift-bin/swift-6.4.2-RELEASE-ubi10.tar.gz\n'
                'RUN chown -R '+user+' /swift-bin\n'
                'USER '+user+'\n'
                'RUN cd /swift-bin && HOME=/swift-bin makepkg --noconfirm\n'
                'USER root\n'
                'RUN pacman -U --noconfirm /swift-bin/*.pkg.tar.zst && rm -rf /swift-bin\n'
            )
            go_setup = ''
            path = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        else:
            tool_setup = 'COPY toolchain.tar.gz /toolchain.tar.gz\nRUN mkdir -p /opt/swift && tar -xzf /toolchain.tar.gz -C /opt/swift --strip-components=2 && rm /toolchain.tar.gz\n'
            go_setup = 'COPY --from=go /usr/local/go/ /opt/go/\n'
            path = '/opt/swift/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        dockerfile = work / 'Dockerfile'
        dockerfile.write_text('FROM golang:1.27.3 AS go\nFROM '+base+'\nRUN '+setup+'\n'+tool_setup+go_setup+'ENV PATH='+path+'\nRUN mkdir -p /work /out && chown '+user+' /work /out\nUSER '+user+'\nENV HOME=/work/home TMPDIR=/work/tmp\nWORKDIR /work\n')
        names = subprocess.check_output(['git', 'ls-files', '-c', '-o', '--exclude-standard', '-z'], cwd=ROOT).split(b'\0')
        archive = work / 'catflap-0.1.0.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for raw in sorted(set(names)):
                if raw:
                    name = os.fsdecode(raw)
                    tar.add(ROOT/name, arcname='catflap-0.1.0/'+name, recursive=False)
        try:
            run(['docker', 'build', '--force-rm', '-t', image, '-f', str(dockerfile), str(work)], env=dict(os.environ, DOCKER_BUILDKIT='0'))
            command = 'set -euo pipefail; mkdir -p /work/home /work/tmp; tar -xzf /input/source.tar.gz -C /work; cd /work/catflap-0.1.0; go version; swift --version; '
            if kind == 'arch':
                checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
                command += 'mkdir -p /work/aur; cp packaging/aur/PKGBUILD /work/aur/; cd /work/aur; CATFLAP_SOURCE_URL=file:///input/source.tar.gz CATFLAP_SOURCE_SHA256='+checksum+' makepkg --noconfirm; cp *.pkg.tar.zst /out/; cp src/catflap-0.1.0/build/package-manifest.txt /out/manifest.txt'
            else:
                command += 'python3 scripts/package/probe-toolchain.py /out; CATFLAP_PACKAGE_OUTPUT=/out bash scripts/package/build.sh '+kind
            run(['docker', 'run', '--rm', '--name', unique+'-build', '-v', str(archive)+':/input/source.tar.gz:ro', '-v', str(output)+':/out', image, 'bash', '-c', command])
            run(['docker', 'run', '--rm', '--name', unique+'-runtime', '-v', str(output)+':/artifacts:ro', '-v', str(ROOT/'scripts/package/smoke.py')+':/smoke.py:ro', base, 'sh', '-c', 'set -eu; '+runtime+'; python3 /smoke.py '+kind])
            print('PASS '+args.target+': clean build, separate no-Swift runtime, version, status, ldd, uninstall', flush=True)
        finally:
            found = subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if found.returncode == 0:
                run(['docker', 'image', 'rm', image])

if __name__ == '__main__':
    main()
