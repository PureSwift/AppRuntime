# AppRuntime Bundle Format Specification

**Format version: 1**

This document specifies the AppRuntime app bundle format completely enough to
author, package, validate, and launch a bundle with no other reference.

## 1. Overview

An app bundle is a self-contained, immutable directory tree carrying an app's
executables (for one or more CPU architectures), its resources, and a JSON
manifest. Bundles are:

- **authored** as a plain directory named `<bundle-id>.app/`;
- **distributed/installed** as a squashfs image of that directory, optionally
  made self-executing (§7).

The OS provides shared runtime libraries (Swift, SDL3, etc.) in its rootfs;
bundles carry only what the OS does not provide (§4).

## 2. Directory layout

```
<bundle-id>.app/
├── manifest.json          required   §3
├── bin/
│   └── <arch>/
│       └── <executable>   required   one per declared architecture
├── lib/                   optional   §4
│   └── <arch>/*.so*
├── resources/             optional   §5
├── run.sh                 optional   §6
└── icon.png               optional   app icon (PNG)
```

`<arch>` is one of the architecture identifiers in §3.1. All paths inside a
bundle are relative; a bundle must contain no absolute paths.

Compatibility symlinks at the bundle root are permitted (e.g. `data ->
resources` for an app that opens `./data`); they must resolve inside the
bundle.

## 3. Manifest (`manifest.json`)

UTF-8 JSON object at the bundle root. Unknown keys must be ignored by readers.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `formatVersion` | integer | yes | Bundle-format version. This spec: `1`. |
| `id` | string | yes | Reverse-DNS bundle identifier. Must be a single safe path component (§3.2). |
| `name` | string | yes | Human-readable display name. |
| `description` | string | yes | Human-readable description. |
| `sdk` | string | yes | SDK/runtime version the app targets. Reserved: no compatibility handling is defined in format version 1. |
| `executable` | string | yes | Executable file name (basename only, §3.2). Resolved as `bin/<arch>/<executable>`. |
| `version` | string | yes | App version. |
| `build` | string | yes | App build number. |
| `copyright` | string | no | Copyright notice. |
| `capabilities` | array of strings | no | Requested capabilities. Defined values: `Display`, `Audio`, `Network`, `Bluetooth`, `NFC`. Absent array = no capabilities. |
| `architectures` | array of strings | yes | Architectures shipped in `bin/`, non-empty (§3.1). |

Example:

```json
{
  "architectures" : [ "arm64", "x86_64" ],
  "build" : "1",
  "capabilities" : [ "Display", "Audio" ],
  "copyright" : "© 2026 Example",
  "description" : "An example app",
  "executable" : "myapp",
  "formatVersion" : 1,
  "id" : "com.example.myapp",
  "name" : "My App",
  "sdk" : "1.0",
  "version" : "1.2.3"
}
```

### 3.1 Architecture identifiers

`arm64`, `armv7`, `armv6`, `armv5`, `x86_64`, `i386`.

Mapping from `uname -m`: `aarch64`/`arm64` → `arm64`; `x86_64`/`amd64` →
`x86_64`; `i386`–`i686` → `i386`; `armv7*` → `armv7`; `armv6*` → `armv6`;
`armv5*` → `armv5`.

### 3.2 Validation

A bundle must be rejected before launch when any of the following fails:

1. `manifest.json` exists and parses as JSON with all required keys.
2. `id` and `executable` are each a *safe path component*: non-empty, not `.`
   or `..`, containing no `/` and no NUL.
3. `architectures` is non-empty.
4. For every declared architecture `a`, the file `bin/<a>/<executable>` exists.

## 4. Private libraries (`lib/`)

`lib/<arch>/` holds shared objects the app needs that the OS rootfs does not
provide. Rules:

- A library must **not** be bundled if the target sysroot/rootfs already ships
  the same soname; packaging tools should check the sysroot and exclude
  automatically.
- Launchers set `LD_LIBRARY_PATH` to the selected architecture's `lib/<arch>`
  directory when it exists. Binaries may additionally embed
  `rpath $ORIGIN/../../lib/<arch>`.

## 5. Resources (`resources/`)

Architecture-independent files (art, audio, data). The library API resolves
`path(forResource:ofType:)` and `resourcePath` against this directory.
Lookups must reject names containing `..`.

## 6. Launch

### 6.1 Architecture selection

Given the host's native architecture, optional 32-bit compatibility
(AArch32 on arm64, x86 multilib on x86_64), and available binary translators
(`box64`: x86_64→arm64, `box86`: x86→armhf), pick the **first** entry present
in the manifest's `architectures` and runnable on the host:

| Host | Preference order |
|---|---|
| `arm64` | `arm64` → `armv7` (needs AArch32) → `x86_64` via box64 (needs box64) → `i386` via box86 (needs box86 **and** AArch32) |
| `armv7` | `armv7` → `i386` via box86 (needs box86) |
| `x86_64` | `x86_64` → `i386` (needs multilib) |

If none matches, launch fails with an error listing bundle architectures and
host capabilities. Note box86 is itself a 32-bit armhf binary: it requires
AArch32 support; on 64-bit-only cores box64 is the only x86 path.

### 6.2 Launch contract

The launcher (any of: the system `bundle-runtime`, `run.sh`, or a
self-executing image) must:

1. Select an architecture (§6.1); let `E = bin/<arch>/<executable>`.
2. Set `LD_LIBRARY_PATH` to `lib/<arch>` if that directory exists.
3. **Set the working directory to the bundle root** (apps may open
   cwd-relative paths such as `./data`).
4. Exec `E`, prefixed by the translator command when one was selected
   (`box64 E` / `box86 E`).

The system launcher additionally mounts the bundle read-only at `/app`,
exports `BUNDLE_PATH=/app`, and applies sandboxing (out of scope for this
document). `AppBundle.main` resolves from `BUNDLE_PATH`, defaulting to `/app`.

### 6.3 `run.sh`

An optional POSIX-sh script at the bundle root implementing §6.1–6.2 with no
dependency on the Swift runtime or system launcher. It must be executable and
must exit non-zero with a diagnostic when no binary is runnable.

## 7. Packaging

### 7.1 squashfs image

```
mksquashfs <bundle-dir> <id>.app.squashfs -comp zstd -all-root -noappend
```

The image mounts read-only; the mounted root is the bundle root.

### 7.2 Self-executing image (AppImage-style polyglot)

A squashfs image may be made directly executable:

1. Pack with `-offset 4096`, leaving the first 4096 bytes zeroed.
2. Overwrite the first bytes (`dd conv=notrunc`) with a `#!/bin/sh` header
   that: resolves its own absolute path, creates a temporary mount point,
   mounts itself with `squashfuse -o offset=4096` (preferred) or
   `mount -o loop,offset=4096,ro`, runs `<mountpoint>/run.sh "$@"`, and
   unmounts on exit (trap on `EXIT INT TERM`). The header must fit in 4096
   bytes.
3. `chmod 755` the image.

The kernel executes the file as a shell script (the `#!` at byte 0); squashfs
tooling and the self-mount header read the filesystem at offset 4096.
Requires `squashfuse` (unprivileged) or root (loop mount).

## 8. Reference implementation

- Manifest model & JSON coding: `Sources/AppRuntime/Manifest.swift`
- Architecture identifiers & host detection: `Sources/AppRuntime/Arch.swift`
- Host capability probing: `Sources/AppRuntime/HostCapabilities.swift`
- Selection algorithm (§6.1): `Sources/AppRuntime/ArchSelector.swift`
- Bundle loading, validation (§3.2), resource lookup (§5): `Sources/AppRuntime/AppBundle.swift`
- Packaging scripts implementing §6.3 and §7: `examples/*/build.sh`
