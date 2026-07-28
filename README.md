# AppRuntime

Portable Cross-Platform Swift App Runtime.

A multi-architecture app bundle format and sandboxing launcher for Linux
appliance systems (Buildroot). One bundle carries binaries for several
architectures; the runtime picks the best one for the host — falling back to
32-bit compatibility or box64/box86 translation — and launches it isolated in
its own namespaces.

## Components

| | |
|---|---|
| `AppRuntime` | Library: manifest model, architecture selection, bundle loading and resource lookup. Corelibs-free (FoundationEssentials only). |
| `bundle-runtime` | Launcher: resolves a bundle, selects an architecture, and execs it inside a sandbox. |
| `CBundleRuntime` | C shim for namespaces, mounts, `pivot_root`, `prctl`, and seccomp. |

## Bundle layout

```
com.example.myapp.app/
├── manifest.json
├── bin/<arch>/myapp        arm64, armv7, armv6, armv5, x86_64, i386
├── lib/<arch>/             optional: only libraries the OS lacks
├── resources/              optional
├── run.sh                  optional: launch without the runtime
└── icon.png
```

Bundles are authored as directories and shipped as squashfs images, optionally
made self-executing like an AppImage.

## Usage

```sh
bundle-runtime com.example.myapp        # by identifier
bundle-runtime /path/to/bundle.app      # by path
```

Run as root for the full sandbox with a per-app uid; unprivileged launches
sandbox via user namespaces instead.

## Documentation

- [Bundle format specification](Documentation/BundleFormat.md) — layout,
  manifest, architecture selection, packaging.
- [Sandbox](Documentation/Sandbox.md) — isolation model, capabilities,
  seccomp, and how to verify it on hardware.

## Examples

[`examples/`](examples) contains build scripts that package real apps as
bundles, cross-compiled against a Swift SDK sysroot: Celeste Classic
(`ccleste`) and Nanosaur 2.

## Building

```sh
swift build
swift test
```

Cross-compile for the target with a Swift SDK:

```sh
swift build --swift-sdk aarch64-unknown-linux-gnu -c release
```
