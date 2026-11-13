#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" = 0 ]; then
  uid=${CALLER_UID:-1000}; gid=${CALLER_GID:-1000}
  groupadd -o -g "$gid" gnome-test
  useradd -o -u "$uid" -g "$gid" -d /run/gnome-home gnome-test
  mkdir -p /run/gnome-home /run/gnome-test
  chown -R "$uid:$gid" /repo/.build /repo/build /run/gnome-home /run/gnome-test
  exec setpriv --reuid="$uid" --regid="$gid" --clear-groups env HOME=/run/gnome-home "$0" "$@"
fi
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.local/share/gnome-shell/extensions/catflap-probe@localhost"
chmod 700 "$XDG_RUNTIME_DIR"
cp /repo/spikes/gnome/extension/* "$HOME/.local/share/gnome-shell/extensions/catflap-probe@localhost/"
export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland
export DBUS_SYSTEM_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --nopidfile)
exec dbus-run-session -- bash -c '
set -u
gsettings set org.gnome.shell enabled-extensions "[\"catflap-probe@localhost\"]"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell welcome-dialog-last-shown-version "999"
gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x720 >"$XDG_RUNTIME_DIR/shell.log" 2>&1 &
pid=$!
trap "kill $pid 2>/dev/null || true" EXIT
for i in $(seq 1 80); do
  [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break
  kill -0 "$pid" || { cat "$XDG_RUNTIME_DIR/shell.log"; exit 70; }
  sleep .25
done
export WAYLAND_DISPLAY=wayland-0
export GOCACHE=/repo/build/go-cache GOPATH=/repo/build/go
sleep 4
if [ "${1:-}" = swift ] && [ "${2:-}" != --version ]; then
  scripts/build-libtailcat.sh || exit $?
fi
"$@"
status=$?
if [ "$status" != 0 ]; then cat "$XDG_RUNTIME_DIR/shell.log" >&2; fi
exit "$status"
' session "$@"
