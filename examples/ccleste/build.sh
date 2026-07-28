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
# Environment:
#   SYSROOT   Target sysroot to cross-compile against (e.g. the swift-linux
#             Swift SDK's sysroot-<arch>). When set, the script cross-compiles
#             with clang + lld and builds sdl2-compat / SDL2_mixer as needed.
#             When unset, builds natively with the repo Makefile.
#   CLANG     C compiler for cross builds (default: ~/.swiftly/bin/clang).
#
# Private libraries: ccleste needs SDL2 + SDL2_mixer. The bundle carries a
# library under lib/<arch>/ ONLY when the sysroot does not already provide it —
# anything shipped by the OS rootfs (e.g. SDL3, and SDL2 once sdl2-compat is
# added to the image) is excluded automatically, keeping bundles thin.
#
# Note: ccleste loads its assets from a `data/` directory relative to the
# working directory, so the launcher chdirs to the bundle root (`/app`) before
# exec; the script stages the data both at `resources/` (AppRuntime convention)
# and `data/` (what the binary opens).

set -eu

BUNDLE_ID="io.github.lemon32767.ccleste"
EXECUTABLE="ccleste"
VERSION="1.0"
REPO="https://github.com/lemon32767/ccleste"
SDL2_COMPAT_REPO="https://github.com/libsdl-org/sdl2-compat"
SDL_MIXER_REPO="https://github.com/libsdl-org/SDL_mixer"
SDL_MIXER_TAG="release-2.8.1"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/src"
DEPS_DIR="$BUILD_DIR/deps"
BUNDLE_DIR="$BUILD_DIR/$BUNDLE_ID.app"
CLANG=${CLANG:-"$HOME/.swiftly/bin/clang"}

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

# Map an AppRuntime Arch to a clang target triple.
triple_for_arch() {
    case "$1" in
        arm64)  echo "aarch64-unknown-linux-gnu" ;;
        x86_64) echo "x86_64-unknown-linux-gnu" ;;
        armv7)  echo "armv7-unknown-linux-gnueabihf" ;;
        x86)    echo "i686-unknown-linux-gnu" ;;
        *)      echo "no triple for architecture: $1" >&2; exit 1 ;;
    esac
}

# True if the sysroot already provides the given library soname.
sysroot_provides() {
    [ -n "${SYSROOT:-}" ] && find "$SYSROOT/usr/lib" "$SYSROOT/lib" \
        -name "$1" -print -quit 2>/dev/null | grep -q .
}

# Stage a private library into the bundle unless the OS already ships it.
stage_lib() {
    soname=$(basename "$1")
    if sysroot_provides "$soname"; then
        echo "    skipping $soname (provided by sysroot)"
    else
        echo "    bundling $soname"
        mkdir -p "$BUNDLE_DIR/lib/$ARCH"
        cp "$1" "$BUNDLE_DIR/lib/$ARCH/$soname"
    fi
}

ARCH=${1:-$(normalize_arch "$(uname -m)")}

echo "==> Fetching $REPO"
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 "$REPO" "$SRC_DIR"
fi

if [ -n "${SYSROOT:-}" ]; then
    TRIPLE=$(triple_for_arch "$ARCH")
    TOOLCHAIN="$BUILD_DIR/toolchain-$ARCH.cmake"
    echo "==> Cross-compiling for $ARCH against $SYSROOT"

    cat > "$TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${TRIPLE%%-*})
set(CMAKE_SYSROOT "$SYSROOT")
set(CMAKE_C_COMPILER "$CLANG")
set(CMAKE_C_COMPILER_TARGET $TRIPLE)
add_link_options(-fuse-ld=lld)
set(CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

    # SDL2 API: use the sysroot's SDL2 if present, else build sdl2-compat
    # (SDL2 implemented on the OS's SDL3) into the local deps prefix.
    if ! sysroot_provides "libSDL2-2.0.so.0"; then
        [ -d "$BUILD_DIR/sdl2-compat" ] || git clone --depth 1 "$SDL2_COMPAT_REPO" "$BUILD_DIR/sdl2-compat"
        cmake -S "$BUILD_DIR/sdl2-compat" -B "$BUILD_DIR/deps-build/sdl2-compat-$ARCH" \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" -DSDL2COMPAT_TESTS=OFF
        cmake --build "$BUILD_DIR/deps-build/sdl2-compat-$ARCH" --parallel
        cmake --install "$BUILD_DIR/deps-build/sdl2-compat-$ARCH"
    fi

    if ! sysroot_provides "libSDL2_mixer-2.0.so.0"; then
        [ -d "$BUILD_DIR/SDL_mixer" ] || git clone --depth 1 --branch "$SDL_MIXER_TAG" "$SDL_MIXER_REPO" "$BUILD_DIR/SDL_mixer"
        cmake -S "$BUILD_DIR/SDL_mixer" -B "$BUILD_DIR/deps-build/SDL_mixer-$ARCH" \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" -DCMAKE_PREFIX_PATH="$DEPS_DIR" \
            -DSDL2_DIR="$DEPS_DIR/lib/cmake/SDL2" \
            -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF \
            -DSDL2MIXER_FLAC=OFF -DSDL2MIXER_MOD=OFF -DSDL2MIXER_MIDI=OFF \
            -DSDL2MIXER_OPUS=OFF -DSDL2MIXER_MP3=OFF -DSDL2MIXER_WAVPACK=OFF \
            -DSDL2MIXER_VORBIS=STB
        cmake --build "$BUILD_DIR/deps-build/SDL_mixer-$ARCH" --parallel
        cmake --install "$BUILD_DIR/deps-build/SDL_mixer-$ARCH"
    fi

    echo "==> Building $EXECUTABLE for $ARCH"
    BINARY="$BUILD_DIR/$EXECUTABLE-$ARCH"
    "$CLANG" -target "$TRIPLE" --sysroot="$SYSROOT" -fuse-ld=lld -O2 \
        -I"$DEPS_DIR/include/SDL2" -I"$SYSROOT/usr/include/SDL2" -D_REENTRANT \
        "$SRC_DIR/sdl12main.c" "$SRC_DIR/celeste.c" \
        -L"$DEPS_DIR/lib" -lSDL2 -lSDL2_mixer -lm \
        -Wl,-rpath,'$ORIGIN/../../lib/'"$ARCH" \
        -o "$BINARY"
else
    echo "==> Building natively for $ARCH"
    make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
    make -C "$SRC_DIR"
    BINARY="$SRC_DIR/$EXECUTABLE"
fi

[ -f "$BINARY" ] || { echo "error: built executable not found" >&2; exit 1; }

echo "==> Staging bundle at $BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin/$ARCH" "$BUNDLE_DIR/resources"
install -m 755 "$BINARY" "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE"
strip "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE" 2>/dev/null || true

# Private libraries — only those the OS does not already provide.
if [ -d "$DEPS_DIR/lib" ]; then
    echo "==> Staging private libraries"
    for lib in "$DEPS_DIR/lib"/libSDL2-2.0.so.0 "$DEPS_DIR/lib"/libSDL2_mixer-2.0.so.0; do
        [ -f "$lib" ] && stage_lib "$lib"
    done
fi

# Graphics, sounds, and music are architecture-independent.
cp -R "$SRC_DIR/data/." "$BUNDLE_DIR/resources/"
# The binary opens `data/` relative to the working directory.
ln -sfn resources "$BUNDLE_DIR/data"
cp "$SRC_DIR/icon.png" "$BUNDLE_DIR/icon.png"

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
        command -v box86 >/dev/null 2>&1 && run x86 box86
        ;;
    armv7*)
        run armv7
        command -v box86 >/dev/null 2>&1 && run x86 box86
        ;;
    x86_64|amd64)
        run x86_64
        run x86
        ;;
    i?86)
        run x86
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
