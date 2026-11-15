#!/usr/bin/env python3
"""Verify installed runtime, control service and complete manifest removal."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

kind = sys.argv[1]
def run(args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(args, check=True, **kwargs)
assert shutil.which('swift') is None, 'Runtime image contains a Swift toolchain'
print('No Swift compiler on target', flush=True)
run(['catflap', '--version'])
linked = subprocess.check_output(['ldd', '/usr/lib/catflap/catflap'], text=True)
print(linked, flush=True)
assert 'not found' not in linked
assert '/opt/swift' not in linked and '/usr/lib/swift' not in linked
# The clean runtime may load its distro's XML through GTK/appstream. Reject
# compiler/build directories, not native sonames that happen to match a tool.
for line in linked.splitlines():
    fields = line.split('=>', 1)[-1].split()
    if not fields:
        continue
    path = fields[0]
    if path.startswith('/'):
        assert path.startswith(('/lib/', '/lib64/', '/usr/lib/', '/usr/lib64/')), path
assert '/usr/lib/catflap/libswiftCore.so' in linked
with tempfile.TemporaryDirectory(prefix='catflap-package-agent-') as tmp:
    env = dict(os.environ, HOME=tmp, CATFLAP_PLATFORM='off', XDG_CONFIG_HOME=tmp+'/config', XDG_DATA_HOME=tmp+'/data', XDG_RUNTIME_DIR=tmp+'/run')
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DBUS_SESSION_BUS_ADDRESS', 'LD_LIBRARY_PATH'):
        env.pop(key, None)
    Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
    data = tmp + '/agent'
    # Keep agent output private: startup may contain transport identity details.
    with open(tmp+'/agent.log', 'wb') as log:
        agent = subprocess.Popen(['catflap', 'agent', '--data-dir', data], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 45
            while not Path(data, 'control.sock').exists():
                assert agent.poll() is None, 'Agent exited before control socket was ready'
                if time.monotonic() >= deadline:
                    raise AssertionError('Agent control socket not ready in 45 seconds')
                time.sleep(0.1)
            status = subprocess.run(['catflap', 'status', '--data-dir', data], env=env, capture_output=True, timeout=70)
            assert status.returncode == 0, 'status failed with exit '+str(status.returncode)
            assert status.stdout.strip(), 'Empty status response'
            print('catflap status: exit 0, nonempty control response (identity output withheld)', flush=True)
        finally:
            if agent.poll() is None:
                agent.terminate()
            try:
                code = agent.wait(timeout=7)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
                raise AssertionError('Agent did not stop within 7 seconds')
            assert code == 0, 'Agent stopped abnormally: '+str(code)
if kind == 'deb':
    run(['dpkg', '--purge', 'catflap'])
elif kind == 'rpm':
    run(['rpm', '-e', 'catflap'])
else:
    run(['pacman', '-R', '--noconfirm', 'catflap'])
manifest = Path('/artifacts/manifest.txt').read_text().splitlines()
left = [p for p in manifest if Path(p).exists() or Path(p).is_symlink()]
assert not left, left
assert not Path('/usr/lib/catflap').exists() or not list(Path('/usr/lib/catflap').iterdir())
assert shutil.which('catflap') is None
print('Uninstall: zero manifest files remain ('+str(len(manifest))+' checked)', flush=True)
