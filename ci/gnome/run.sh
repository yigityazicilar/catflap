#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
image=${CATFLAP_GNOME_IMAGE:-catflap-gnome-test:51}
if ! docker image inspect "$image" >/dev/null 2>&1 || [ "${GNOME_REBUILD:-0}" = 1 ]; then
  DOCKER_BUILDKIT=0 docker build -t "$image" "$root/ci/gnome"
fi
# Persistent, container-only caches never overlap the host toolchain's directories.
cache=${CATFLAP_GNOME_CACHE:-catflap-gnome-51}
# Docker otherwise creates these host mount points as root in a fresh clone.
mkdir -p "$root/.build" "$root/build"
evidence_args=()
if [ -n "${CATFLAP_GNOME_EVIDENCE:-}" ]; then
  mkdir -p "$CATFLAP_GNOME_EVIDENCE"
  evidence_args=(-v "$CATFLAP_GNOME_EVIDENCE:/evidence")
fi
exec docker run "${evidence_args[@]}" --rm --shm-size=1g --entrypoint /repo/ci/gnome/session.sh -e CALLER_UID="$(id -u)" -e CALLER_GID="$(id -g)" -v "$root:/repo" \
  -v "$cache-swift:/repo/.build" -v "$cache-native:/repo/build" "$image" "$@"
