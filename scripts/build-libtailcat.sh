#!/usr/bin/env bash
# Build only the pinned C ABI, keeping fetched sources and outputs out of git.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
commit=e00cdde6ff787f801361ff85ed085775c775d4c5
source_dir="$root/.build/tailcat-src"
out="$root/build/lib"
case "$(uname -s)" in
    Linux) library=libtailcat.so ;;
    Darwin)
        library=libtailcat.dylib
        # Downloaded Swift toolchains do not discover Apple's C SDK automatically.
        export SDKROOT="${SDKROOT:-$(xcrun --toolchain default --sdk macosx --show-sdk-path)}"
        export CC="${CC:-$(xcrun --toolchain default --find clang)}"
        ;;
    *) printf '%s\n' 'Unsupported operating system' >&2; exit 1 ;;
esac
mkdir -p "$out"
# Include the compiler, architecture and build configuration in the cache key.
fingerprint="$commit|$(go version)|$(go env GOOS GOARCH CC CGO_ENABLED)|${CC:-}|${SDKROOT:-}|${CGO_CFLAGS:-}|${CGO_LDFLAGS:-}|${GOFLAGS:-}"
if [[ -s "$out/$library" && -f "$out/build-fingerprint" ]] && [[ "$(cat "$out/build-fingerprint")" == "$fingerprint" ]]; then
    printf '%s\n' "$commit"
    exit 0
fi
if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$source_dir"
    git -C "$source_dir" init -q
fi
if ! git -C "$source_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$source_dir" fetch -q --depth=1 https://github.com/tailscale/tailcat.git "$commit"
fi
# Extract the exact commit, not a moving branch or the state of a working tree.
git -C "$source_dir" archive "$commit" | tar -x -C "$source_dir"
if ! cmp -s "$source_dir/cmd/libtailcat/tailcat.h" "$root/Sources/CTailcat/tailcat.h"; then
    printf '%s\n' 'CTailcat header differs from the pinned upstream header' >&2
    exit 1
fi
(
    cd "$source_dir"
    CGO_ENABLED=1 go build -buildmode=c-shared -tags "$(cat build-tags.txt)" -o "$out/$library" ./cmd/libtailcat
)
if [[ "$library" == libtailcat.dylib ]]; then
    install_name_tool -id '@rpath/libtailcat.dylib' "$out/$library"
fi
printf '%s\n' "$fingerprint" > "$out/build-fingerprint"
printf '%s\n' "$commit"
