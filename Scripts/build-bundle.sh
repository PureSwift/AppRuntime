#!/bin/sh
# Builds every slice of a package's guest library product and assembles the
# universal bundle (§7.5) that is handed to a host:
#
#   <id>.app/
#   ├── Info.plist                  RTTargets, RTABIVersion, RTCapabilities, RTContracts;
#   │                               with --manifest, RTPlatforms, RTCapabilityUsage, …
#   ├── wasm32/App.wasm             always included
#   ├── lib/<target>/libapp.a       sealed native slices
#   ├── resources/                  --resources, or the manifest's resources/
#   ├── icon.png                    --icon
#   └── _CodeSignature/CodeResources  per-file SHA-256 hashes (unsigned)
#
# Usage:
#   Scripts/build-bundle.sh --manifest App.swift [--target …] [--package PATH]
#   Scripts/build-bundle.sh --product ExampleApp --id org.example.app \
#       --name Example --version 1.0 --build 1 [--target all|ios|linux|...] \
#       [--capability bluetooth] [--resources DIR] [--icon FILE] [--package PATH]
#
# See `Scripts/guest.py targets` for target IDs and groups.
set -eu
exec python3 "$(dirname "$0")/guest.py" bundle "$@"
