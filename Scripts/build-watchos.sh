#!/bin/sh
# Compiles a package's guest library product for watchOS 6 (arm64).
# Slices go to <package>/.build/guest/<product>/<target>/.
#
# Usage: Scripts/build-watchos.sh <product> [package-path]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <product> [package-path]" >&2; exit 2; }
exec python3 "$(dirname "$0")/guest.py" slice --product "$1" --package "${2:-.}" --target watchos
