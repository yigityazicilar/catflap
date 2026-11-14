#!/bin/bash
# Builds build/Catflap.app: the catflap executable, libtailcat beside it, an Info.plist for an
# agent app with no Dock or app-switcher entry (and a Services item for Finder), and the
# launch agent that starts it at login, signed under one fixed identifier.
#
#   packaging/macos/bundle.sh [--binary PATH] [--output DIR] [--configuration release|debug]
#
#   --binary PATH         bundle this catflap executable instead of building one
#   --output DIR          write DIR/Catflap.app (default: build/ in the checkout)
#   --configuration NAME  the swift build configuration (default: release)
#
# CATFLAP_SIGN_IDENTITY names the signing identity, as `security find-identity -v -p
# codesigning` lists it (a name or a SHA-1). Without it the app is signed ad hoc, and macOS
# will not let the next build read the keys this one stored in the Keychain.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
identifier="io.github.yigityazicilar.Catflap"
binary=""
output="$root/build"
configuration="release"

while (($#)); do
    case "$1" in
        --binary) binary="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --configuration) configuration="$2"; shift 2 ;;
        *) echo "usage: bundle.sh [--binary PATH] [--output DIR] [--configuration release|debug]" >&2; exit 64 ;;
    esac
done

if [[ -z "$binary" ]]; then
    (cd "$root" && swift build -c "$configuration" --product catflap)
    binary="$(cd "$root" && swift build -c "$configuration" --show-bin-path)/catflap"
fi
[[ -x "$binary" ]] || { echo "bundle.sh: no catflap executable at $binary" >&2; exit 1; }
library="$root/build/lib/libtailcat.dylib"
[[ -f "$library" ]] || { echo "bundle.sh: run scripts/build-libtailcat.sh first" >&2; exit 1; }

# The bundle's version comes from the executable itself.
version="$("$binary" version | sed -n 's/^Catflap \([0-9.]*\).*/\1/p')"
[[ -n "$version" ]] || { echo "bundle.sh: could not read the version from $binary" >&2; exit 1; }

app="$output/Catflap.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/catflap"
cp "$library" "$app/Contents/Frameworks/libtailcat.dylib"
# Resource bundles of the packages (KeyboardShortcuts' strings) sit beside the executable.
for resources in "$(dirname "$binary")"/*.bundle; do
    if [[ -d "$resources" ]]; then cp -R "$resources" "$app/Contents/Resources/"; fi
done
executable="$app/Contents/MacOS/catflap"
# Libraries the build linked from outside macOS (a package manager's SQLite, found through
# pkg-config) go into Frameworks as well, so the app needs nothing macOS does not have.
dependencies="$(otool -L "$executable" | tail -n +2 | awk '{ print $1 }')"
while IFS= read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/*|@*|"") ;;
        /*)
            name="$(basename "$dependency")"
            copy="$app/Contents/Frameworks/$name"
            cp -L "$dependency" "$copy"
            chmod u+w "$copy"
            install_name_tool -id "@rpath/$name" "$copy"
            install_name_tool -change "$dependency" "@rpath/$name" "$executable"
            # One level only: what such a library needs must itself be part of macOS.
            nested="$(otool -L "$copy" | tail -n +3 | awk '{ print $1 }' | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@' || true)"
            [[ -z "$nested" ]] || { echo "bundle.sh: $name needs libraries outside macOS: $nested" >&2; exit 1; }
            ;;
    esac
done <<< "$dependencies"
# A development build finds libtailcat in the checkout through an absolute rpath, and the
# toolchain may add its own. The app must not depend on either: drop every absolute rpath
# outside the system, so libtailcat comes only from the bundle's Frameworks.
rpaths="$(otool -l "$executable" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }' | sort -u)"
while IFS= read -r path; do
    case "$path" in
        /usr/lib/*|/System/*|"") ;;
        # The linker can record one path twice; remove every copy.
        /*) while [[ "$(otool -l "$executable")" == *"path $path (offset"* ]]; do
                install_name_tool -delete_rpath "$path" "$executable"
            done ;;
    esac
done <<< "$rpaths"
# The library's install name is @rpath/libtailcat.dylib; find it inside the bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$executable"
sed -e "s/@IDENTIFIER@/$identifier/" -e "s/@VERSION@/$version/" "$root/packaging/macos/Info.plist" > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
# Start at login: the launch agent SMAppService registers when the person switches it on.
mkdir -p "$app/Contents/Library/LaunchAgents"
agent="$app/Contents/Library/LaunchAgents/$identifier.agent.plist"
sed -e "s/@IDENTIFIER@/$identifier/g" "$root/packaging/macos/$identifier.agent.plist" > "$agent"
plutil -lint -s "$agent"

identity="${CATFLAP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    echo "warning: CATFLAP_SIGN_IDENTITY is not set; signing ad hoc. Keychain access will not survive the next rebuild." >&2
    identity="-"
fi
# Inside out: the libraries first, then the app, which signs its executable under the app's
# identifier.
for library in "$app/Contents/Frameworks/"*.dylib; do
    codesign --force --timestamp=none --sign "$identity" "$library"
done
codesign --force --timestamp=none --sign "$identity" --identifier "$identifier" "$app"
codesign --verify --strict --deep "$app"
echo "$app"
