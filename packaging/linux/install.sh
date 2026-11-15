#!/bin/bash
# Installs Catflap for one person on Linux, without root: the catflap executable, libtailcat
# and the Swift runtime libraries it was linked against, all in PREFIX/lib/catflap, so the
# installed build runs with the source checkout gone and no library path set. Also the
# desktop entry (the GlobalShortcuts portal finds the app by it), the icons, and the
# autostart entry that starts the agent at login.
#
#   packaging/linux/install.sh [--prefix DIR] [--binary PATH | --configuration NAME] [--no-autostart]
#   packaging/linux/install.sh --uninstall [--prefix DIR]
#
#   --prefix DIR     where to install (default: ~/.local)
#   --binary PATH    install this catflap executable instead of building a release one
#   --configuration NAME  the swift build configuration when building (default: release)
#   --no-autostart   do not start Catflap at login (it can be switched on in Settings)
#   --uninstall      remove what an install put in PREFIX, the autostart entry and Dolphin's
#                    "Send with Catflap" menu; the data folder (history, keys) is left alone
#
# The autostart entry and the Dolphin menu go under $XDG_CONFIG_HOME and $XDG_DATA_HOME.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/packaging/linux"
app="io.github.yigityazicilar.Catflap"
prefix="$HOME/.local"
binary=""
configuration="release"
autostart=1
uninstall=0

while (($#)); do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        --binary) binary="$2"; shift 2 ;;
        --configuration) configuration="$2"; shift 2 ;;
        --no-autostart) autostart=0; shift ;;
        --uninstall) uninstall=1; shift ;;
        *) echo "usage: install.sh [--prefix DIR] [--binary PATH] [--configuration NAME] [--no-autostart] | --uninstall [--prefix DIR]" >&2; exit 64 ;;
    esac
done

mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
libdir="$prefix/lib/catflap"
autostart_file="$config_home/autostart/$app.desktop"
service_menu="$data_home/kio/servicemenus/$app.desktop"
icons="$prefix/share/icons/hicolor/scalable/apps"

if ((uninstall)); then
    # Stop a running agent first, so nothing runs from files that are about to go.
    if [[ -x "$prefix/bin/catflap" ]]; then
        pkill -TERM -f "^$libdir/catflap agent" 2>/dev/null || true
    fi
    rm -rf "$libdir"
    rm -f "$prefix/bin/catflap" "$prefix/share/applications/$app.desktop" "$autostart_file" "$service_menu"
    rm -f "$icons/$app.svg" "$icons/$app"-*-symbolic.svg
    echo "Removed Catflap from $prefix. The data folder was left in place."
    exit 0
fi

if [[ -z "$binary" ]]; then
    (cd "$root" && swift build -c "$configuration" --product catflap)
    binary="$(cd "$root" && swift build -c "$configuration" --show-bin-path)/catflap"
fi
[[ -x "$binary" ]] || { echo "install.sh: no catflap executable at $binary" >&2; exit 1; }
library="$root/build/lib/libtailcat.so"
[[ -f "$library" ]] || { echo "install.sh: run scripts/build-libtailcat.sh first" >&2; exit 1; }

mkdir -p "$libdir" "$prefix/bin" "$prefix/share/applications" "$icons"
install -m 0755 "$binary" "$libdir/catflap"
install -m 0644 "$library" "$libdir/libtailcat.so"

# The Swift runtime: every library the executable loads from the toolchain's own folder.
# The executable's run path includes $ORIGIN, so these copies serve where no toolchain is.
swift_core="$(ldd "$binary" | awk '$1 == "libswiftCore.so" { print $3 }')"
if [[ -n "$swift_core" ]]; then
    runtime="$(dirname "$(readlink -f "$swift_core")")"
    ldd "$binary" | awk '$2 == "=>" { print $3 }' | while read -r path; do
        if [[ -n "$path" && "$(dirname "$(readlink -f "$path")")" == "$runtime" ]]; then
            install -m 0644 "$(readlink -f "$path")" "$libdir/$(basename "$path")"
        fi
    done
fi
missing="$(cd "$libdir" && ldd ./catflap | awk '/not found/ { print $1 }')"
[[ -z "$missing" ]] || { echo "install.sh: libraries not found for the installed catflap: $missing" >&2; exit 1; }

ln -sfn "../lib/catflap/catflap" "$prefix/bin/catflap"

# The desktop entry names the installed executable by its full path, so the portal and the
# session start it whether or not PREFIX/bin is on PATH.
quoted="$prefix/bin/catflap"
[[ "$quoted" =~ [[:space:]\"\`\$\\] ]] && quoted="\"$(printf '%s' "$quoted" | sed 's/[\\"`$]/\\&/g')\""
sed -e "s|^Exec=catflap agent$|Exec=$quoted agent|" -e "s|^TryExec=catflap$|TryExec=$prefix/bin/catflap|" \
    "$here/$app.desktop" > "$prefix/share/applications/$app.desktop"
chmod 0644 "$prefix/share/applications/$app.desktop"
install -m 0644 "$here/icons/$app.svg" "$icons/"
install -m 0644 "$here"/icons/"$app"-*-symbolic.svg "$icons/"

if ((autostart)); then
    mkdir -p "$(dirname "$autostart_file")"
    sed -e "s|^Exec=catflap agent$|Exec=$quoted agent|" -e "s|^TryExec=catflap$|TryExec=$prefix/bin/catflap|" \
        -e '/^SingleMainWindow=/d' "$here/$app.desktop" > "$autostart_file"
    printf 'NoDisplay=true\nX-GNOME-Autostart-enabled=true\nX-KDE-autostart-phase=2\n' >> "$autostart_file"
fi

command -v update-desktop-database >/dev/null && update-desktop-database -q "$prefix/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true

echo "Installed Catflap in $prefix."
"$prefix/bin/catflap" version
