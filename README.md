# AppRuntime

A portable app runtime. Apps are written once in **Embedded Swift**, built
as a wasm32 module and optional native static libraries, and run inside a
native host on iOS, macOS, Android and Linux. Guest and host talk only
through a small dynamic-runtime C ABI, [`rt.h`](Sources/CRuntime/include/rt.h),
modeled on the Objective-C runtime and reduced to what Objective-C, JNI and C
all support. Platforms implement portable **contracts** declared as Swift
protocols.

- **Design:** [Documentation/DynamicRuntime.md](Documentation/DynamicRuntime.md)
- **Phase one status, decisions and findings:** [Documentation/Implementation.md](Documentation/Implementation.md)

This repository holds the shared, platform-independent code (the ABI, the
guest library and macros, the runtime core, the provider contracts, the
guest build scripts), the wasm import shim, and the Linux bundle launcher
and sandbox. Platform hosts and UI renderers (iOS, Android, Linux) are
written separately.

## Packages

| Target | Role | Embedded |
|---|---|---|
| `CRuntime` | `rt.h`, plus `rt_guest.h` (ABI version, section names, wasm allocator) | C, freestanding |
| `RuntimeABI` | Wire types, signatures, status codes, contract descriptors, `rt.contracts` encoding | yes |
| `DynamicRuntime` | Guest library: `rt_*` wrappers, proxies, marshaling, `rt_dispatch` / `rt_finalize`, `List`, macros | yes |
| `DynamicRuntimeMacros` | `@DynamicRuntime` / `@DynamicCallback`: proxies, dispatch adapters, metadata records | build machine |
| `RuntimeCore` | Runtime core: handle table, registry, Swift-registry backend, validation | yes |
| `RuntimeNative` | `rt_*` as C symbols, for native slices and host Swift code | yes |
| `RuntimeWasm` | WasmKit import shim: runs `App.wasm` against `RuntimeCore` | host |
| `DynamicBluetooth`, `DynamicLocation`, `DynamicNetworking`, `DynamicFormatting` | Provider contracts (declarations) | yes |
| `AppRuntime`, `bundle-runtime`, `CBundleRuntime` | Linux bundle model, launcher and sandbox | Linux |

## A contract

```swift
import DynamicRuntime

@DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
public protocol Central: AnyObject {
    static func make(_ delegate: CentralDelegate) -> Self
    func state() -> Int32
    func scan(services: [String], allowDuplicates: Bool)
}
```

The macro generates `CentralProxy` (calls through `rt_call`), the descriptor
and an `rt.contracts` record, plus adapters that export a Swift
implementation to the runtime. Guest code uses `CentralProxy.make(delegate)`;
a Swift host registers `CentralProxy.register(MyCentral.self, in: registrar)`.

An app exports one entry point and no `main`. `Runtime.main` runs the async
work it starts before returning to the host:

```swift
@_expose(wasm, "rt_main")
@c(rt_main)
public func appMain() -> rt_status {
    Runtime.main { App.start() }
}
```

Async code runs on the guest executor: tasks run before each call from the
host returns, and `RuntimeClock.sleep(nanoseconds:)` stands in for
`Task.sleep`, which Embedded Swift doesn't have.

## Building

The toolchain is pinned in `.swift-version` (Swift 6.4.2). Install it and
the matching wasm Swift SDK:

```sh
swiftly install 6.4.2
swift sdk install https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
```

```sh
swift build
swift test
```

### Guest slices and bundles

`Scripts/guest.py` compiles a package's guest library product for each
target, seals every native slice (§7.5), links `App.wasm` as a WASI reactor
and assembles the universal bundle a host consumes. It builds no host code.

```sh
Scripts/build-wasm.sh ExampleApp        # wasm32
Scripts/build-ios.sh ExampleApp         # iOS 6 armv7, iOS 13 arm64
Scripts/build-macos.sh ExampleApp       # macOS 10.15, arm64 + x86_64
Scripts/build-tvos.sh ExampleApp        # tvOS 13
Scripts/build-watchos.sh ExampleApp     # watchOS 6 (arm64)
Scripts/build-visionos.sh ExampleApp    # visionOS 1
Scripts/build-linux.sh ExampleApp       # armv7, arm64, x86_64
Scripts/build-android.sh ExampleApp     # armeabi-v7a, arm64-v8a, x86_64
```

```sh
Scripts/build-bundle.sh --product ExampleApp --id org.pureswift.example \
    --name Example --version 1.0 --build 1 --capability bluetooth
```

`Scripts/guest.py targets` lists every target ID. Output goes to
`.build/guest/<product>/`.

The toolchain has no Embedded concurrency runtime for the arm64 ELF slices'
bare-metal triple, so `linux-arm64` and `android-arm64-v8a` use the one for
`aarch64-unknown-linux-gnu`. arm64 Linux toolchains include it. Elsewhere,
copy it from the `swift` Docker image once per Swift version:

```sh
Scripts/fetch-embedded-linux.sh
```

Without it, those two slices are built without concurrency.

`RuntimeWasmTests` runs the example app's `App.wasm` when it has been built
(`Scripts/build-wasm.sh ExampleApp`), the same app `DynamicRuntimeTests` runs
as a native slice.

## Linux bundle launcher

`bundle-runtime` resolves a bundle, selects an architecture and launches it
inside a namespace sandbox. See [Sandbox](Documentation/Sandbox.md). The
[bundle format](Documentation/BundleFormat.md) it implements predates the
universal bundle of the new design (§7.5) and will move to it.

```sh
bundle-runtime com.example.myapp        # by identifier
bundle-runtime /path/to/bundle.app      # by path
```

Use CMake to cross-compile and install the launcher and `libAppRuntime.so`
for a target system (the Swift language requires the Ninja generator):

```sh
cmake -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/linux.toolchain.cmake \
  -DAPPRUNTIME_ARCH=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr
```

```sh
cmake --build build && DESTDIR=/path/to/rootfs cmake --install build
```

| Option | Default | Meaning |
|---|---|---|
| `APPRUNTIME_ARCH` | `arm64` | Target: `arm64`, `x86_64`, `armv7`, `i386` |
| `APPRUNTIME_SYSROOT` | Swift SDK sysroot for the arch | Override the target sysroot |
| `APPRUNTIME_TOOLCHAIN_BIN` | `~/.swiftly/bin` | Directory holding `clang`/`swiftc` |
| `APPRUNTIME_BUILD_LAUNCHER` | `ON` | Build `bundle-runtime` (Linux only) |
| `BUILD_SHARED_LIBS` | `ON` | Build the library shared rather than static |

[`examples/`](examples) also holds build scripts that package Celeste Classic
(`ccleste`) and Nanosaur 2 as port bundles.
