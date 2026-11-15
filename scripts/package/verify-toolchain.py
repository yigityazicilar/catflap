#!/usr/bin/env python3
"""Authenticate official Swift archives before recording their SHA-256 pins."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
parser.add_argument('--keys', type=Path, help='Reuse keys already fetched from swift.org/keys/all-keys.asc')
parser.add_argument('platform', choices=['ubuntu2604', 'debian13', 'fedora41', 'ubi10'])
args = parser.parse_args()
name = {'ubuntu2604': 'ubuntu26.04', 'debian13': 'debian13', 'fedora41': 'fedora41', 'ubi10': 'ubi10'}[args.platform]
url = 'https://download.swift.org/swift-6.4.2-release/'+args.platform+'/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-'+name+'.tar.gz'
with tempfile.TemporaryDirectory(prefix='catflap-swift-signature-') as tmp:
    env = dict(os.environ, GNUPGHOME=tmp)
    key = Path(tmp) / 'keys.asc'
    sig = Path(tmp) / 'toolchain.sig'
    if args.keys:
        key.write_bytes(args.keys.read_bytes())
    else:
        subprocess.run(['curl', '-fsSL', 'https://swift.org/keys/all-keys.asc', '-o', str(key)], check=True)
    subprocess.run(['curl', '-fsSL', url+'.sig', '-o', str(sig)], check=True)
    imported = subprocess.run(['gpg', '--batch', '--import', str(key)], env=env, capture_output=True, text=True)
    if imported.returncode:
        raise RuntimeError(imported.stderr)
    verified = subprocess.run(['gpg', '--batch', '--status-fd', '1', '--verify', str(sig), str(args.archive)], env=env, check=True, capture_output=True, text=True)
    for line in verified.stderr.splitlines():
        if 'Good signature' in line:
            print(line, flush=True)
    for line in verified.stdout.splitlines():
        if line.startswith('[GNUPG:] VALIDSIG '):
            print(line, flush=True)
    digest = hashlib.file_digest(args.archive.open('rb'), 'sha256').hexdigest()
    print(args.platform, digest, flush=True)
