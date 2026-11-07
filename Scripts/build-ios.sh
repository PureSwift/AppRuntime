#!/bin/sh
# Compiles a package's guest library product for iOS 6 (armv7) and iOS 13 (arm64).
# Slices go to <package>/.build/guest/<product>/<target>/.
#
# Usage: Scripts/build-ios.sh <product> [package-path]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <product> [package-path]" >&2; exit 2; }
exec python3 "$(dirname "$0")/guest.py" slice --product "$1" --package "${2:-.}" --target ios
