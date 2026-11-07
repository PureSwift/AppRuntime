#!/bin/sh
# Compiles a package's guest library product for Android armeabi-v7a, arm64-v8a, x86_64.
# Slices go to <package>/.build/guest/<product>/<target>/.
#
# Usage: Scripts/build-android.sh <product> [package-path]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <product> [package-path]" >&2; exit 2; }
exec python3 "$(dirname "$0")/guest.py" slice --product "$1" --package "${2:-.}" --target android
