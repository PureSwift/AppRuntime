#!/bin/sh
#
# Build a GNOME-style web application as an AppRuntime bundle: a
# single-site browser shell on GTK4 + WebKitGTK, equivalent to GNOME
# Web's "Install as Web App".
#
# Produces:
#   build/org.gnome.Webapp.app/                 authored bundle folder
#   build/org.gnome.Webapp.app.squashfs         self-executing image
#
# Usage:
#   ./build.sh [arch]
#
#   arch    Bundle architecture directory to stage the binary under.
#           Defaults to the host architecture (uname -m, normalized).
#
# Environment:
#   SYSROOT     Target sysroot to cross-compile against (e.g. the
#               swift-linux Swift SDK's sysroot-<arch>). Required for
#               cross builds; omit to build natively.
#   CLANG       C compiler for cross builds (default: ~/.swiftly/bin/clang)
#   APP_URL     Site to open (default: https://www.gnome.org/)
#   APP_NAME    Window title and display name (default: GNOME Web App)
#   APP_ID      Bundle identifier (default: org.gnome.Webapp)
#
# REQUIREMENTS — read before running:
#
# This example needs **GTK 4** and **WebKitGTK 6.0** development files in
# the target sysroot, and the matching runtime libraries in the target
# rootfs. Neither is present in the stock swift-linux SDK sysroot, so the
# Buildroot image must enable them first:
#
#   BR2_PACKAGE_LIBGTK4=y
#   BR2_PACKAGE_WEBKITGTK=y
#
# WebKitGTK is a large dependency (well over 100 MB installed, with a long
# build). It belongs in the rootfs, not the bundle: per the format's
# private-library rule the bundle must not carry libraries the OS provides,
# and a browser engine is emphatically shared infrastructure.
#
# The script fails fast with a precise message if the libraries are absent.

set -eu

BUNDLE_ID=${APP_ID:-"org.gnome.Webapp"}
EXECUTABLE="gnome-webapp"
VERSION="1.0"
APP_URL=${APP_URL:-"https://www.gnome.org/"}
APP_NAME=${APP_NAME:-"GNOME Web App"}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$SCRIPT_DIR/src"
BUNDLE_DIR="$BUILD_DIR/$BUNDLE_ID.app"
CLANG=${CLANG:-"$HOME/.swiftly/bin/clang"}

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

# Map an AppRuntime Arch to a clang target triple.
triple_for_arch() {
    case "$1" in
        arm64)  echo "aarch64-unknown-linux-gnu" ;;
        x86_64) echo "x86_64-unknown-linux-gnu" ;;
        armv7)  echo "armv7-unknown-linux-gnueabihf" ;;
        i386)   echo "i686-unknown-linux-gnu" ;;
        *)      echo "no triple for architecture: $1" >&2; exit 1 ;;
    esac
}

# True if the sysroot (or host) provides the given library soname.
have_lib() {
    if [ -n "${SYSROOT:-}" ]; then
        find "$SYSROOT/usr/lib" "$SYSROOT/lib" -name "$1" -print -quit 2>/dev/null | grep -q .
    else
        ldconfig -p 2>/dev/null | grep -q "$1"
    fi
}

ARCH=${1:-$(normalize_arch "$(uname -m)")}

echo "==> Checking for GTK 4 and WebKitGTK"
missing=""
have_lib "libgtk-4.so*" || missing="$missing GTK4(libgtk-4.so)"
have_lib "libwebkitgtk-6.0.so*" || missing="$missing WebKitGTK(libwebkitgtk-6.0.so)"
if [ -n "$missing" ]; then
    cat >&2 <<EOF
error: missing required libraries:$missing

This example needs GTK 4 and WebKitGTK 6.0 in the target rootfs/sysroot.
Enable them in the Buildroot configuration and regenerate the SDK:

    BR2_PACKAGE_LIBGTK4=y
    BR2_PACKAGE_WEBKITGTK=y

They belong in the OS image, not the bundle: a browser engine is shared
infrastructure, and the bundle format forbids carrying libraries the OS
already provides.
EOF
    exit 1
fi

echo "==> Building $EXECUTABLE for $ARCH"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/$EXECUTABLE-$ARCH"

# pkg-config must resolve against the target sysroot, not the host.
if [ -n "${SYSROOT:-}" ]; then
    PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
    PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR
fi

if command -v cmake >/dev/null 2>&1; then
    # Preferred: the example's CMakeLists, consistent with the rest of
    # the repo and directly reusable from a Buildroot package recipe.
    CMAKE_DIR="$BUILD_DIR/cmake-$ARCH"
    set -- -S "$SCRIPT_DIR" -B "$CMAKE_DIR" -DCMAKE_BUILD_TYPE=Release \
        -DAPP_URL="$APP_URL" -DAPP_NAME="$APP_NAME" -DAPP_ID="$BUNDLE_ID" \
        -DAPPRUNTIME_ARCH="$ARCH"
    # Prefer Ninja: it is the generator the rest of the repo uses, and
    # minimal build environments often ship it without make.
    if command -v ninja >/dev/null 2>&1; then
        set -- "$@" -G Ninja
    fi
    if [ -n "${SYSROOT:-}" ]; then
        TRIPLE=$(triple_for_arch "$ARCH")
        set -- "$@" \
            -DCMAKE_SYSTEM_NAME=Linux \
            -DCMAKE_SYSROOT="$SYSROOT" \
            -DCMAKE_C_COMPILER="$CLANG" \
            -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
            -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld"
    fi
    cmake "$@"
    cmake --build "$CMAKE_DIR" --parallel
    cp "$CMAKE_DIR/$EXECUTABLE" "$BINARY"
else
    # Fallback: compile directly when CMake is unavailable.
    echo "    cmake not found; compiling directly"
    DEFINES="-DAPP_URL=\"$APP_URL\" -DAPP_NAME=\"$APP_NAME\" -DAPP_ID=\"$BUNDLE_ID\""
    CFLAGS=$(pkg-config --cflags gtk4 webkitgtk-6.0)
    LIBS=$(pkg-config --libs gtk4 webkitgtk-6.0)
    if [ -n "${SYSROOT:-}" ]; then
        TRIPLE=$(triple_for_arch "$ARCH")
        # shellcheck disable=SC2086
        "$CLANG" -target "$TRIPLE" --sysroot="$SYSROOT" -fuse-ld=lld -O2 \
            $DEFINES $CFLAGS "$SRC_DIR/main.c" $LIBS -o "$BINARY"
    else
        # shellcheck disable=SC2086
        cc -O2 $DEFINES $CFLAGS "$SRC_DIR/main.c" $LIBS -o "$BINARY"
    fi
fi

echo "==> Staging bundle at $BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin/$ARCH" "$BUNDLE_DIR/resources"
install -m 755 "$BINARY" "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE"
strip "$BUNDLE_DIR/bin/$ARCH/$EXECUTABLE" 2>/dev/null || true

# No private libraries: GTK and WebKit come from the OS rootfs.

if [ -f "$SCRIPT_DIR/icon.png" ]; then
    cp "$SCRIPT_DIR/icon.png" "$BUNDLE_DIR/icon.png"
fi

echo "==> Writing run.sh"
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
  "capabilities" : [ "Display", "Network" ],
  "description" : "$APP_NAME, a single-site browser built on GTK4 and WebKitGTK",
  "executable" : "$EXECUTABLE",
  "formatVersion" : 1,
  "id" : "$BUNDLE_ID",
  "name" : "$APP_NAME",
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
