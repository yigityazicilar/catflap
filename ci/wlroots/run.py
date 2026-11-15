#!/usr/bin/env python3
"""Build in a disposable copy, never the read-only source or a host Swift cache."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
    os.environ.pop(name, None)
with tempfile.TemporaryDirectory(prefix="catflap-wlroots-") as temporary:
    work = Path(temporary)
    tree = work / "tree"
    shutil.copytree("/src", tree, ignore=shutil.ignore_patterns(".git", ".build", "__pycache__", "build"))
    os.environ.update(HOME=str(work / "home"), TMPDIR=str(work / "tmp"), CI="true", CATFLAP_WLROOTS_TESTS="1")
    Path(os.environ["HOME"]).mkdir()
    Path(os.environ["TMPDIR"]).mkdir(mode=0o700)
    for command in (["swift", "--version"], ["go", "version"], ["dpkg-query", "-W", "sway", "libwlroots12t64", "wl-clipboard", "wtype"], ["scripts/build-libtailcat.sh"], ["python3", "scripts/ci-test.py", "--filter", "Wlroots"]):
        print("+ " + " ".join(command), flush=True)
        subprocess.run(command, cwd=tree, check=True)
