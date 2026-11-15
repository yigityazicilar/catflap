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
#   --prefix DIR     where to install (default: PREFIX or ~/.local)
#   --destdir DIR    stage a system package under DIR with --prefix /usr --binary PATH
#   --list           print the system payload paths for --prefix /usr --binary PATH
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
prefix="${PREFIX:-$HOME/.local}"
binary=""
configuration="release"
autostart=1
uninstall=0
destdir="${DESTDIR:-}"
list=0

while (($#)); do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        --destdir) destdir="$2"; shift 2 ;;
        --list) list=1; shift ;;
        --binary) binary="$2"; shift 2 ;;
        --configuration) configuration="$2"; shift 2 ;;
        --no-autostart) autostart=0; shift ;;
        --uninstall) uninstall=1; shift ;;
        *) echo "usage: install.sh [--prefix DIR] [--binary PATH] [--configuration NAME] [--no-autostart] | --uninstall [--prefix DIR]" >&2; exit 64 ;;
    esac
done

# This is the payload manifest for both per-user and system installs. Additional
# file-manager drop-ins belong here, not in individual package recipes.
payload() {
    printf '%s\t%s\n' "$binary" 'lib/catflap/catflap'
    printf '%s\t%s\n' "$root/build/lib/libtailcat.so" 'lib/catflap/libtailcat.so'
    local swift_core runtime path
    swift_core="$(ldd "$binary" | awk '$1 == "libswiftCore.so" { print $3 }')"
    if [[ -n "$swift_core" ]]; then
        runtime="$(dirname "$(readlink -f "$swift_core")")"
        while read -r path; do
            if [[ -f "$path" && "$(dirname "$(readlink -f "$path")")" == "$runtime" ]]; then
                printf '%s\tlib/catflap/%s\n' "$(readlink -f "$path")" "$(basename "$path")"
            fi
        done < <(ldd "$binary" | awk '$2 == "=>" { print $3 }')
    fi
    printf '%s\tshare/applications/%s.desktop\n' "$here/$app.desktop" "$app"
    for path in "$here/icons/$app.svg" "$here"/icons/"$app"-*-symbolic.svg; do
        printf '%s\tshare/icons/hicolor/scalable/apps/%s\n' "$path" "$(basename "$path")"
    done
    # Future file-manager drop-ins extend this function once for all recipes.
}

if [[ -n "$destdir" || "$list" == 1 ]]; then
    [[ "$prefix" == /usr && -x "$binary" ]] || { echo 'System staging requires --prefix /usr --binary PATH' >&2; exit 64; }
    if ((list)); then
        payload | while IFS=$'\t' read -r source target; do printf '%s/%s\n' "$prefix" "$target"; done
        printf '%s/bin/catflap\n' "$prefix"
    else
        while IFS=$'\t' read -r source target; do
            install -Dm644 "$source" "$destdir$prefix/$target"
        done < <(payload)
        chmod 755 "$destdir$prefix/lib/catflap/catflap"
        install -Dm755 "$root/scripts/package/launcher" "$destdir$prefix/bin/catflap"
    fi
    exit 0
fi

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
while IFS=$'\t' read -r source target; do
    install -Dm644 "$source" "$prefix/$target"
done < <(payload)
chmod 755 "$libdir/catflap"
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
