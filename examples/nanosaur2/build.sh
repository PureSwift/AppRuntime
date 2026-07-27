#!/bin/sh
#
# Build Nanosaur 2 (https://github.com/jorio/Nanosaur2) as an AppRuntime bundle.
#
# Produces:
#   build/io.jorio.nanosaur2.app/       authored bundle folder
#   build/io.jorio.nanosaur2.app.squashfs   installable image (if mksquashfs is available)
#
# Usage:
#   ./build.sh [arch]
#
#   arch    Bundle architecture directory to stage the binary under.
#           Defaults to the host architecture (uname -m, normalized).
#
# Cross-compiling: run once per architecture with the matching toolchain
# environment (CC/CXX or a CMake toolchain file via CMAKE_TOOLCHAIN_FILE),
# passing the target arch; binaries accumulate under bin/<arch>/ and the
# manifest's `architectures` array is regenerated from the staged directories.
#
# Requirements: git, cmake, a C++20 compiler, SDL3 development headers.

set -eu

BUNDLE_ID="io.jorio.nanosaur2"
EXECUTABLE="Nanosaur2"
VERSION="2.1.0"
REPO="https://github.com/jorio/Nanosaur2"
TAG="v2.1.0"

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

echo "==> Fetching $REPO ($TAG)"
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 --branch "$TAG" --recurse-submodules "$REPO" "$SRC_DIR"
fi

echo "==> Building for $ARCH"
cmake -S "$SRC_DIR" -B "$BUILD_DIR/cmake-$ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
cmake --build "$BUILD_DIR/cmake-$ARCH" --parallel

BINARY="$BUILD_DIR/cmake-$ARCH/$EXECUTABLE"
[ -f "$BINARY" ] || BINARY=$(find "$BUILD_DIR/cmake-$ARCH" -maxdepth 2 -type f -name "$EXECUTABLE" | head -n 1)
[ -n "$BINARY" ] && [ -f "$BINARY" ] || { echo "error: built executable not found" >&2; exit 1; }

echo "==> Staging bundle at $BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin/$ARCH" "$BUNDLE_DIR/assets"
install -m 755 "$BINARY" "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE"
strip "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE" 2>/dev/null || true

# Game data (art, audio, models, terrain) is architecture-independent.
cp -R "$SRC_DIR/Data/." "$BUNDLE_DIR/assets/"

# Icon
if [ -f "$SRC_DIR/packaging/icon.png" ]; then
    cp "$SRC_DIR/packaging/icon.png" "$BUNDLE_DIR/icon.png"
fi

echo "==> Writing manifest.json"
# Regenerate the architectures array from every staged bin/<arch>/ directory,
# so repeated cross-builds accumulate into one fat bundle.
ARCHES=$(ls "$BUNDLE_DIR/bin" | sed 's/.*/"&"/' | paste -sd, -)
cat > "$BUNDLE_DIR/manifest.json" <<EOF
{
  "architectures" : [ $ARCHES ],
  "build" : "1",
  "capabilities" : [ "Display", "Audio" ],
  "copyright" : "© 2008 Pangea Software; port © Iliyas Jorio",
  "description" : "Fly a pterodactyl through lush 3D landscapes on a mission to save dinosaurkind",
  "executable" : "$EXECUTABLE",
  "formatVersion" : 1,
  "id" : "$BUNDLE_ID",
  "name" : "Nanosaur 2",
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
