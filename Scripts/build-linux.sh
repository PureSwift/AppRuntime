#!/bin/sh
# Compiles a package's guest library product for Linux armv7, arm64, x86_64.
# Each slice is <package>/.build/guest/<product>/<target>/libapp.so, which a
# runner loads as it is.
#
# Usage: Scripts/build-linux.sh <product> [package-path]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <product> [package-path]" >&2; exit 2; }
exec python3 "$(dirname "$0")/guest.py" slice --product "$1" --package "${2:-.}" --target linux
