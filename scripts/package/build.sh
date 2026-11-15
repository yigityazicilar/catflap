#!/bin/bash
set -euo pipefail
kind="$1"
[[ "$(swift --version)" == *'Swift version 6.4.2 '* ]] || { echo 'Packages require Swift 6.4.2' >&2; exit 1; }
version="${CATFLAP_VERSION:-0.1.0}"
case "$version" in *[!0-9.]*|'') echo 'Invalid package version' >&2; exit 64;; esac
pkg-config --atleast-version=1.0.4 gtk4-layer-shell-0
pkg-config --modversion gtk4 libadwaita-1 gtk4-layer-shell-0 wayland-client gtk4-x11
scripts/build-libtailcat.sh
# Swift 6.4.2's default build system mis-resolves swiftc outside /usr.
# The measured native backend works with the same unmodified toolchain.
swift build --build-system native -c release --product catflap --jobs "${CATFLAP_BUILD_JOBS:-4}"
binary="$(swift build --build-system native -c release --show-bin-path)/catflap"
stage="$PWD/build/package-root"
out="${CATFLAP_PACKAGE_OUTPUT:-$PWD/build/packages}"
mkdir -p "$stage" "$out"
bash packaging/linux/install.sh --prefix /usr --binary "$binary" --destdir "$stage"
bash packaging/linux/install.sh --prefix /usr --binary "$binary" --list | sort -u > build/package-manifest.txt
# Remove all development/toolchain runpaths, including transitive Swift libraries.
for file in "$stage"/usr/lib/catflap/*; do
    patchelf --set-rpath '$ORIGIN' "$file"
done
python3 - "$stage" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
stage = Path(sys.argv[1])
dynamic = subprocess.check_output(['readelf', '-d', str(stage/'usr/lib/catflap/catflap')], text=True)
needed = re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic)
assert not any(name.startswith('libxml2') for name in needed), needed
print('Direct ELF NEEDED (no toolchain XML dependency):', needed)
expected = set(Path('build/package-manifest.txt').read_text().splitlines())
actual = {'/' + str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file() or p.is_symlink()}
assert actual == expected, (actual - expected, expected - actual)
print('Staged payload exactly matches installer manifest:', len(expected), 'files')
PY
case "$kind" in
    deb)
        mkdir -p "$stage/DEBIAN"
        sed "s/@VERSION@/$version/g" packaging/deb/control > "$stage/DEBIAN/control"
        dpkg-deb --root-owner-group --build "$stage" "$out/catflap_${version}_amd64.deb"
        ;;
    rpm)
        mkdir -p build/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
        cp build/package-manifest.txt build/rpmbuild/SOURCES/files.list
        rpmbuild -bb --define "_topdir $PWD/build/rpmbuild" --define "catflap_version $version" --define "payload $stage" packaging/rpm/catflap.spec
        cp build/rpmbuild/RPMS/*/*.rpm "$out/"
        rpm -qpR "$out"/*.rpm | tee "$out/rpm-requires.txt"
        rpm -qp --provides "$out"/*.rpm | tee "$out/rpm-provides.txt"
        ;;
    stage) ;;
    *) exit 64 ;;
esac
cp build/package-manifest.txt "$out/manifest.txt"
