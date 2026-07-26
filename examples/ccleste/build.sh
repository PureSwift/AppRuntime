#!/bin/sh
#
# Build ccleste — the C port of Celeste Classic (PICO-8)
# (https://github.com/lemon32767/ccleste) — as an AppRuntime bundle.
#
# Produces:
#   build/io.github.lemon32767.ccleste.app/       authored bundle folder
#   build/io.github.lemon32767.ccleste.app.squashfs   installable image (if mksquashfs is available)
#
# Usage:
#   ./build.sh [arch]
#
#   arch    Bundle architecture directory to stage the binary under.
#           Defaults to the host architecture (uname -m, normalized).
#
# Cross-compiling: run once per architecture with the matching toolchain
# environment (CC/CFLAGS pointing at the target sysroot), passing the target
# arch; binaries accumulate under bin/<arch>/ and the manifest's
# `architectures` array is regenerated from the staged directories.
#
# Note: ccleste loads its assets from a `data/` directory relative to the
# working directory, so the launcher should chdir to the bundle root (`/app`)
# before exec; the script stages the data both at `assets/` (AppRuntime
# convention) and `data/` (what the binary opens).
#
# Requirements: git, a C compiler, make, SDL2 and SDL2_mixer development headers.

set -eu

BUNDLE_ID="io.github.lemon32767.ccleste"
EXECUTABLE="ccleste"
VERSION="1.0"
REPO="https://github.com/lemon32767/ccleste"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/src"
BUNDLE_DIR="$BUILD_DIR/$BUNDLE_ID.app"

# Normalize `uname -m` to an AppRuntime Arch raw value.
normalize_arch() {
    case "$1" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        i?86)          echo "x86" ;;
        armv7*)        echo "armv7" ;;
        armv6*)        echo "armv6" ;;
        *)             echo "unsupported architecture: $1" >&2; exit 1 ;;
    esac
}

ARCH=${1:-$(normalize_arch "$(uname -m)")}

echo "==> Fetching $REPO"
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 "$REPO" "$SRC_DIR"
fi

echo "==> Building for $ARCH"
make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
make -C "$SRC_DIR"

BINARY="$SRC_DIR/$EXECUTABLE"
[ -f "$BINARY" ] || { echo "error: built executable not found" >&2; exit 1; }

echo "==> Staging bundle at $BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin/$ARCH" "$BUNDLE_DIR/assets"
install -m 755 "$BINARY" "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE"
strip "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE" 2>/dev/null || true

# Graphics, sounds, and music are architecture-independent.
cp -R "$SRC_DIR/data/." "$BUNDLE_DIR/assets/"
# The binary opens `data/` relative to the working directory.
ln -sfn assets "$BUNDLE_DIR/data"

echo "==> Writing manifest.json"
# Regenerate the architectures array from every staged bin/<arch>/ directory,
# so repeated cross-builds accumulate into one fat bundle.
ARCHES=$(ls "$BUNDLE_DIR/bin" | sed 's/.*/"&"/' | paste -sd, -)
cat > "$BUNDLE_DIR/manifest.json" <<EOF
{
  "architectures" : [ $ARCHES ],
  "build" : "1",
  "capabilities" : [ "Display", "Audio" ],
  "copyright" : "Celeste © Maddy Makes Games; C port by lemon32767",
  "description" : "C port of the original Celeste Classic for the PICO-8",
  "executable" : "$EXECUTABLE",
  "formatVersion" : 1,
  "id" : "$BUNDLE_ID",
  "name" : "Celeste Classic",
  "sdk" : "1.0",
  "version" : "$VERSION"
}
EOF

if command -v mksquashfs >/dev/null 2>&1; then
    echo "==> Packing squashfs image"
    rm -f "$BUILD_DIR/$BUNDLE_ID.app.squashfs"
    mksquashfs "$BUNDLE_DIR" "$BUILD_DIR/$BUNDLE_ID.app.squashfs" \
        -comp zstd -all-root -noappend
else
    echo "==> mksquashfs not found; skipping image (bundle folder is complete)"
fi

echo "==> Done: $BUNDLE_DIR"
