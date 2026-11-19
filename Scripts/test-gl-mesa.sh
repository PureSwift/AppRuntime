#!/bin/sh
# Draws examples/ExampleGL on a real GL and checks the pixels: Mesa's
# software renderer in Docker, since a Mac has no OpenGL ES.
#
# It runs the example three times under Scripts/hosts/gl-mesa-host.c:
# - its sealed Linux slice, for the Docker host's architecture, linked in;
# - the same slice as libapp.so, which the host loads as a runner does;
# - its App.wasm translated by wasm2c, with the GL shim.
# All three must draw the same pixels. A host that doesn't export rt.h must
# fail to load libapp.so, naming a symbol it lacks.
#
# Usage: Scripts/test-gl-mesa.sh [output-directory]
#
# Needs Docker, and WABT for the wasm2c half (brew install wabt). The image
# is $GL_MESA_IMAGE, default ubuntu:24.04, and needs clang with Mesa's EGL
# and GLES2; they're installed with apt when missing. The frames are left
# in the output directory as frame1.ppm and frame2.ppm.
set -eu
scripts="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$scripts")"
output="${1:-$root/.build/gl-mesa}"
image="${GL_MESA_IMAGE:-ubuntu:24.04}"

case "$(docker info --format '{{.Architecture}}')" in
    aarch64|arm64) target=linux-arm64 ;;
    x86_64|amd64) target=linux-x86_64 ;;
    *) echo "error: no Linux slice for this Docker host's architecture" >&2; exit 1 ;;
esac

python3 "$scripts/guest.py" slice --product ExampleGL --package "$root" --target wasm --target "$target"
rm -rf "$output"
mkdir -p "$output"
python3 "$scripts/wasm2c-shim.py" sources --wasm "$root/.build/guest/ExampleGL/wasm32/App.wasm" --output "$output/wasm2c"
cp "$root/.build/guest/ExampleGL/$target/libapp.a" "$root/.build/guest/ExampleGL/$target/libapp.so" "$scripts/hosts/gl-mesa-host.c" "$root/Sources/CRuntime/include/rt.h" "$output/"

docker run --rm -v "$output":/work -w /work -e LIBGL_ALWAYS_SOFTWARE=1 "$image" sh -euc '
    if ! command -v clang >/dev/null || [ ! -e /usr/include/GLES2/gl2.h ]; then
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang libegl1-mesa-dev libgles2-mesa-dev libgl1-mesa-dri >/dev/null
    fi
    echo "==> native slice"
    clang -O1 -w -I. gl-mesa-host.c libapp.a -lEGL -lGLESv2 -lm -o host-native
    ./host-native frame1.ppm frame2.ppm
    echo "==> libapp.so, loaded"
    clang -O1 -w -I. -DHOST_LOADS -rdynamic gl-mesa-host.c -lEGL -lGLESv2 -lm -ldl -o host-loads
    ./host-loads ./libapp.so frame1-loaded.ppm frame2-loaded.ppm
    cmp frame1.ppm frame1-loaded.ppm
    cmp frame2.ppm frame2-loaded.ppm
    clang -O1 -w -I. -DHOST_LOADS gl-mesa-host.c -lEGL -lGLESv2 -lm -ldl -o host-exports-nothing
    if ./host-exports-nothing ./libapp.so >refused.txt 2>&1; then
        echo "FAIL libapp.so loaded into a host without rt.h"; exit 1
    fi
    grep -q "undefined symbol: rt_" refused.txt
    echo "ok: a host without rt.h is refused: $(cat refused.txt)"
    echo "==> wasm2c"
    cd wasm2c
    clang -O1 -w $(sed "s/^/-D/" defines.txt) -DHOST_GENERATION -I. ../gl-mesa-host.c $(cat sources.txt) -lEGL -lGLESv2 -lm -o ../host-wasm2c
    cd ..
    ./host-wasm2c frame1-wasm2c.ppm frame2-wasm2c.ppm
    cmp frame1.ppm frame1-wasm2c.ppm
    cmp frame2.ppm frame2-wasm2c.ppm
    echo "ok: all three draw the same pixels"
'
