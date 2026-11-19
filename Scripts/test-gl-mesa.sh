#!/bin/sh
# Draws examples/ExampleGL on a real GL and checks the pixels: Mesa's
# software renderer in Docker, since a Mac has no OpenGL ES.
#
# It runs the example three times under Scripts/hosts/gl-mesa-host.c:
# - its Linux slice, libapp.so, which the host loads as a runner does;
# - its App.wasm as a Linux slice (wasm2c-shim.py slice), loaded the same
#   way;
# - its App.wasm translated by wasm2c, with the GL shim, compiled into the
#   host against the image's libc.
# All three must draw the same pixels. A host that doesn't export rt.h must
# fail to load libapp.so, naming a symbol it lacks.
#
# Usage: Scripts/test-gl-mesa.sh [output-directory]
#
# Needs Docker, and WABT for the wasm2c runs (brew install wabt). The image
# is $GL_MESA_IMAGE, default ubuntu:24.04, and needs clang with Mesa's EGL
# and GLES2; they're installed with apt when missing. The frames are left
# in the output directory as frame1.ppm and frame2.ppm.
#
# $GL_MESA_PLATFORM is the Docker platform, default the Docker host's own:
# linux/arm64, linux/amd64 or linux/arm/v7. Another architecture's runs
# under Docker's emulation, slowly.
#
# $GL_MESA_DRIVER is Mesa's software driver (GALLIUM_DRIVER), default
# Mesa's own choice, llvmpipe. linux/arm/v7 defaults to softpipe: under
# emulation llvmpipe's compiled code crashes there, whatever draws.
set -eu
scripts="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$scripts")"
output="${1:-$root/.build/gl-mesa}"
image="${GL_MESA_IMAGE:-ubuntu:24.04}"

case "${GL_MESA_PLATFORM:-$(docker info --format '{{.Architecture}}')}" in
    aarch64|arm64|linux/arm64) platform=linux/arm64 target=linux-arm64 ;;
    x86_64|amd64|linux/amd64) platform=linux/amd64 target=linux-x86_64 ;;
    linux/arm/v7) platform=linux/arm/v7 target=linux-armv7 driver=softpipe ;;
    *) echo "error: no Linux slice for this platform" >&2; exit 1 ;;
esac
driver="${GL_MESA_DRIVER:-${driver:-}}"

python3 "$scripts/guest.py" slice --product ExampleGL --package "$root" --target wasm --target "$target"
rm -rf "$output"
mkdir -p "$output"
output="$(cd "$output" && pwd)" # Docker takes a relative path for a volume's name
python3 "$scripts/wasm2c-shim.py" sources --wasm "$root/.build/guest/ExampleGL/wasm32/App.wasm" --output "$output/wasm2c"
python3 "$scripts/wasm2c-shim.py" slice --wasm "$root/.build/guest/ExampleGL/wasm32/App.wasm" --output "$output/wasm2c-slice" --target "$target"
cp "$output/wasm2c-slice/$target/libapp.so" "$output/libapp-wasm2c.so"
cp "$root/.build/guest/ExampleGL/$target/libapp.so" "$scripts/hosts/gl-mesa-host.c" "$root/Sources/CRuntime/include/rt.h" "$output/"

# The platform is named: a tag last pulled for another one is otherwise run.
docker run --rm --platform "$platform" -v "$output":/work -w /work -e LIBGL_ALWAYS_SOFTWARE=1 ${driver:+-e GALLIUM_DRIVER="$driver"} "$image" sh -euc '
    if ! command -v clang >/dev/null || [ ! -e /usr/include/GLES2/gl2.h ]; then
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang libegl1-mesa-dev libgles2-mesa-dev libgl1-mesa-dri >/dev/null
    fi
    echo "==> native slice: libapp.so, loaded"
    clang -O1 -w -I. -DHOST_LOADS -DHOST_GENERATION -rdynamic gl-mesa-host.c -lEGL -lGLESv2 -lm -ldl -o host-loads
    ./host-loads ./libapp.so frame1.ppm frame2.ppm
    clang -O1 -w -I. -DHOST_LOADS gl-mesa-host.c -lEGL -lGLESv2 -lm -ldl -o host-exports-nothing
    if ./host-exports-nothing ./libapp.so >refused.txt 2>&1; then
        echo "FAIL libapp.so loaded into a host without rt.h"; exit 1
    fi
    grep -q "undefined symbol: rt_" refused.txt
    echo "ok: a host without rt.h is refused: $(cat refused.txt)"
    echo "==> wasm2c slice: libapp.so, loaded"
    ./host-loads ./libapp-wasm2c.so frame1-wasm2c-slice.ppm frame2-wasm2c-slice.ppm
    cmp frame1.ppm frame1-wasm2c-slice.ppm
    cmp frame2.ppm frame2-wasm2c-slice.ppm
    echo "==> wasm2c, compiled in"
    cd wasm2c
    clang -O1 -w $(sed "s/^/-D/" defines.txt) -DHOST_GENERATION -I. ../gl-mesa-host.c $(cat sources.txt) -lEGL -lGLESv2 -lm -o ../host-wasm2c
    cd ..
    ./host-wasm2c frame1-wasm2c.ppm frame2-wasm2c.ppm
    cmp frame1.ppm frame1-wasm2c.ppm
    cmp frame2.ppm frame2-wasm2c.ppm
    echo "ok: all three draw the same pixels"
'
