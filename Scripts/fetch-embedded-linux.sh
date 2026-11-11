#!/bin/sh
# Copies the Embedded Swift modules and runtime libraries for
# aarch64-unknown-linux-gnu out of the official swift Docker image, for
# guest.py to build linux-arm64 and android-arm64-v8a slices with
# concurrency (Documentation/DynamicRuntime.md §5.4).
#
# The toolchain has no concurrency runtime for aarch64-none-none-elf, the
# bare-metal triple those slices use otherwise. arm64 Linux toolchains ship
# one for aarch64-unknown-linux-gnu; other toolchains (macOS, x86_64 Linux)
# don't. The copy has to come from the same Swift version as the toolchain.
#
# Usage: Scripts/fetch-embedded-linux.sh [swift-version]
#   swift-version defaults to the repository's .swift-version.
# Writes to $RT_EMBEDDED_DIR, or ~/.cache/appruntime/swift-<version>/embedded
# ($XDG_CACHE_HOME instead of ~/.cache if set), where guest.py looks.
# Needs Docker; on an x86_64 machine, arm64 emulation for it.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-$(cat "$ROOT/.swift-version")}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
DEST=${RT_EMBEDDED_DIR:-$CACHE/appruntime/swift-$VERSION/embedded}
TRIPLE=aarch64-unknown-linux-gnu

mkdir -p "$DEST"
docker run --rm --platform linux/arm64 -e TRIPLE="$TRIPLE" -v "$DEST:/out" "swift:$VERSION" sh -c '
    set -eu
    cd /usr/lib/swift/embedded
    for module in *.swiftmodule; do
        if [ -e "$module/$TRIPLE.swiftmodule" ]; then
            mkdir -p "/out/$module"
            cp "$module/$TRIPLE".* "/out/$module/"
        fi
    done
    rm -rf "/out/$TRIPLE"
    cp -R "$TRIPLE" "/out/$TRIPLE"
'
echo "$DEST"
