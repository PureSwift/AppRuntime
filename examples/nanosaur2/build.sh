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
        i?86)          echo "i386" ;;
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
# -include cstdint: the Pomme submodule pinned by v2.1.0 relies on transitive
# <cstdint> includes that newer libstdc++ (GCC 14+) no longer provides.
cmake -S "$SRC_DIR" -B "$BUILD_DIR/cmake-$ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_CXX_FLAGS="-include cstdint"
cmake --build "$BUILD_DIR/cmake-$ARCH" --parallel

BINARY="$BUILD_DIR/cmake-$ARCH/$EXECUTABLE"
[ -f "$BINARY" ] || BINARY=$(find "$BUILD_DIR/cmake-$ARCH" -maxdepth 2 -type f -name "$EXECUTABLE" | head -n 1)
[ -n "$BINARY" ] && [ -f "$BINARY" ] || { echo "error: built executable not found" >&2; exit 1; }

echo "==> Staging bundle at $BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin/$ARCH" "$BUNDLE_DIR/resources"
install -m 755 "$BINARY" "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE"
strip "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE" 2>/dev/null || true

# Game data (art, audio, models, terrain) is architecture-independent.
cp -R "$SRC_DIR/Data/." "$BUNDLE_DIR/resources/"

# Icon
if [ -f "$SRC_DIR/packaging/icon.png" ]; then
    cp "$SRC_DIR/packaging/icon.png" "$BUNDLE_DIR/icon.png"
fi

echo "==> Writing run.sh"
# Self-contained launcher: selects the best architecture and execs the
# binary directly — no Swift runtime or AppRuntime launcher required.
cat > "$BUNDLE_DIR/run.sh" <<EOF
#!/bin/sh
# Launch $BUNDLE_ID without the AppRuntime launcher.
set -eu
DIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
EXECUTABLE=$EXECUTABLE
run() {
    arch=\$1; shift
    BIN="\$DIR/bin/\$arch/\$EXECUTABLE"
    [ -x "\$BIN" ] || return 0
    if [ -d "\$DIR/lib/\$arch" ]; then
        LD_LIBRARY_PATH="\$DIR/lib/\$arch\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
        export LD_LIBRARY_PATH
    fi
    cd "\$DIR"
    exec "\$@" "\$BIN"
}
case "\$(uname -m)" in
    aarch64|arm64)
        run arm64
        run armv7
        command -v box64 >/dev/null 2>&1 && run x86_64 box64
        command -v box86 >/dev/null 2>&1 && run i386 box86
        ;;
    armv7*)
        run armv7
        command -v box86 >/dev/null 2>&1 && run i386 box86
        ;;
    x86_64|amd64)
        run x86_64
        run i386
        ;;
    i?86)
        run i386
        ;;
esac
echo "run.sh: no runnable binary for \$(uname -m)" >&2
exit 1
EOF
chmod 755 "$BUNDLE_DIR/run.sh"

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
    echo "==> Packing self-executing squashfs image"
    IMAGE="$BUILD_DIR/$BUNDLE_ID.app.squashfs"
    rm -f "$IMAGE"
    # AppImage-style polyglot: a shell-script header in the first 4 KiB,
    # squashfs at offset 4096. Executing the file mounts itself (squashfuse,
    # falling back to a loop mount) and runs the bundle's run.sh.
    OFFSET=4096
    mksquashfs "$BUNDLE_DIR" "$IMAGE" \
        -comp zstd -all-root -noappend -quiet -offset "$OFFSET"
    HEADER=$(mktemp)
    cat > "$HEADER" <<EOF
#!/bin/sh
# Self-mounting AppRuntime bundle: squashfs at offset $OFFSET.
set -eu
SELF=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)/\$(basename -- "\$0")
MNT=\$(mktemp -d)
cleanup() {
    umount "\$MNT" 2>/dev/null || fusermount -u "\$MNT" 2>/dev/null || true
    rmdir "\$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
if command -v squashfuse >/dev/null 2>&1; then
    squashfuse -o offset=$OFFSET "\$SELF" "\$MNT"
else
    mount -o loop,offset=$OFFSET,ro "\$SELF" "\$MNT"
fi
"\$MNT/run.sh" "\$@"
EOF
    HEADER_SIZE=$(wc -c < "$HEADER")
    [ "$HEADER_SIZE" -le "$OFFSET" ] || { echo "error: header exceeds offset" >&2; exit 1; }
    dd if="$HEADER" of="$IMAGE" conv=notrunc 2>/dev/null
    rm -f "$HEADER"
    chmod 755 "$IMAGE"
else
    echo "==> mksquashfs not found; skipping image (bundle folder is complete)"
fi

echo "==> Done: $BUNDLE_DIR"
