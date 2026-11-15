#!/bin/bash
# Runs the X11 tests (Tests/CatflapLinuxTests/X11) in the X11 test image: a private Xvfb,
# xfwm4 and session bus per test, real input through XTEST. The tree is copied into the
# container (without .build and build), libtailcat and Catflap are built there with the CI
# toolchain, and the tests run through scripts/ci-test.py. Nothing is written to the tree.
#
#   ci/x11/run.sh [FILTER]       FILTER is passed to swift test --filter (default: X11)
#
#   CATFLAP_X11_IMAGE   the image to use (default catflap-x11-test, built from ci/x11)
#   CATFLAP_X11_WORK    a host folder to build in instead of a fresh tmpfs; it keeps the build
#                       between runs (for local iteration). It must belong to the caller.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${CATFLAP_X11_IMAGE:-catflap-x11-test}"
filter="${1:-X11}"
uid="$(id -u)"
gid="$(id -g)"
if [[ -n "${CATFLAP_X11_WORK:-}" ]]; then
    mkdir -p "$CATFLAP_X11_WORK"
    work=(--mount "type=bind,src=$CATFLAP_X11_WORK,dst=/work")
else
    work=(--tmpfs "/work:exec,uid=$uid,gid=$gid,mode=0700")
fi
# The run itself, inside the container. Only the tree's tracked shape matters: .build and
# build belong to the host's toolchain and are never copied in.
script='
set -euo pipefail
mkdir -p /work/userhome /work/tmp /work/tree
# A kept build folder (CATFLAP_X11_WORK) keeps only its build products: the sources are
# copied afresh, so a file deleted from the tree is gone here too.
find /work/tree -mindepth 1 -maxdepth 1 ! -name .build ! -name build -exec rm -rf {} +
cd /src
tar --exclude=./.build --exclude=./build --exclude=./.git -cf - . | tar -C /work/tree -xf -
cd /work/tree
swift --version
dpkg-query -W xvfb xfwm4 xdotool xclip libx11-dev libxfixes-dev libgtk-4-1
scripts/build-libtailcat.sh
swift build --build-tests
CATFLAP_X11_REQUIRED=1 python3 scripts/ci-test.py --filter "$FILTER"
'
# The session bus refuses to start for a uid the password database does not know, and the
# caller's uid is not in the image when it is not 1000 (GitHub's runners use 1001). The
# image's own entries plus one for the caller, read-only, for this run only.
passwd="$(mktemp "${TMPDIR:-/tmp}/catflap-x11-passwd.XXXXXX")"
trap 'rm -f "$passwd"' EXIT
docker run --rm --entrypoint cat "$image" /etc/passwd > "$passwd"
if ! awk -F: -v uid="$uid" '$3 == uid { found = 1 } END { exit !found }' "$passwd"; then
    printf 'catflap:x:%s:%s:Catflap tests:/work/userhome:/bin/bash\n' "$uid" "$gid" >> "$passwd"
fi
chmod 0644 "$passwd"
docker run --rm --user "$uid:$gid" "${work[@]}" -v "$passwd:/etc/passwd:ro" \
    -e HOME=/work/userhome -e TMPDIR=/work/tmp -e GOPATH=/work/userhome/go -e GOCACHE=/work/userhome/go-cache \
    -e CI="${CI:-}" -e FILTER="$filter" -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$root:/src:ro" --entrypoint bash "$image" -c "$script"
