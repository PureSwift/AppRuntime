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

The package supports macOS 12 and iOS 15, the oldest deployment targets
current Xcode accepts. The WasmKit engine needs macOS 15 / iOS 18, so it is
its own package, [`Packages/RuntimeWasm`](Packages/RuntimeWasm), which
depends on this one by path. Hosts that ship only native slices or wasm2c
don't depend on WasmKit.

| Target | Role | Embedded |
|---|---|---|
| `CRuntime` | `rt.h`, plus `rt_guest.h` (ABI version, section names, wasm allocator) | C, freestanding |
| `RuntimeABI` | Wire types, signatures, status codes, contract descriptors, `rt.contracts` encoding | yes |
| `DynamicRuntime` | Guest library: `rt_*` wrappers, proxies, marshaling, `rt_dispatch` / `rt_finalize` (the `GuestExports` trait), `List`, macros | yes |
| `DynamicRuntimeMacros` | `@DynamicRuntime` / `@DynamicCallback`: proxies, dispatch adapters, metadata records | build machine |
| `RuntimeCore` | Runtime core: handle table, registry, Swift-registry backend, validation | yes |
| `RuntimeNative` | `rt_*` as C symbols for native slices, and a direct binding for host Swift code | yes |
| `RuntimeHost` | What native hosts share: the app's `Info.plist` keys (`AppInfo`), the startup checks, `HostModule` and permission providers, and the generic `Permissions` and `Application` built-ins | host |
| `RuntimeWasm` | WasmKit import shim: runs `App.wasm` against `RuntimeCore`. A separate package in `Packages/RuntimeWasm` | host, macOS 15 / iOS 18 |
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

Every host also provides the built-in `Permissions`, `Bundle` (`AppBundle` in
Swift) and `Application` contracts: one way to ask for any capability, the
app's metadata and localized strings, and its lifecycle and incoming URLs.

```swift
let greeting = try AppBundleProxy.localizedString("greeting", table: nil) ?? "Hello"
if try PermissionsProxy.status(.location) == PermissionStatus.notDetermined.rawValue {
    try PermissionsProxy.request(.location, delegate: permissionsDelegate)
}
let application = try ApplicationProxy.make(lifecycleDelegate)
```

Each provider contract also has async wrappers for guest code, such as
`AsyncCentral`, `AsyncLocationManager` and `HTTPSession.data(for:)`. Event
sequences are `EventStream`s, which stop the native work when released:

```swift
let central = AsyncCentral()
guard await central.requestAuthorization() == .allowed else { return }
for try await result in central.scan(services: [.bit16(0x180D)]) {
    let peripheral = try await central.connect(result.peripheral)
    // …
}
```

## User interface

Guests write SwiftUI. `import SwiftUI` and `import Observation` give guest
builds the Embedded frontend and the Observation stopgap. The frontend does
no layout or rendering: it sends the host's renderer a render IR tree, and
then only what changes (`Documentation/RenderIR.md`).

```swift
@Observable
final class Store {
    var name: String = "World"
}

struct ContentView: View {
    @Bindable var store: Store

    var body: some View {
        VStack {
            Text("Hello, \(store.name)!")
            TextField("Name", text: $store.name)
        }
    }
}

struct ExampleApp: App {
    let store = Store()
    var body: some Scene {
        WindowGroup { ContentView(store: store) }
    }
}

@_expose(wasm, "rt_main")
@c(rt_main)
public func appMain() -> rt_status {
    Runtime.main { ExampleApp.run() }
}
```

`examples/ExampleUI` is a fuller app. No player renders the IR yet.

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

The WasmKit engine's tests run from its own package:

```sh
cd Packages/RuntimeWasm
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

An app's manifest is Swift, like `Package.swift`
([`examples/ExampleAppManifest/App.swift`](examples/ExampleAppManifest/App.swift)):

```swift
import AppManifest

let app = App(
    id: "org.pureswift.example",
    name: .localized("app.name"),
    version: "1.0", build: 1,
    languages: ["en", "es"],
    product: "ExampleApp",
    capabilities: [.bluetooth(usage: .localized("perm.bluetooth"))],
    platforms: [.iOS("15.0"), .macOS("12.0"), .android(minSDK: 26, targetSDK: 35), .linux]
)
```

```sh
Scripts/build-bundle.sh --manifest examples/ExampleAppManifest/App.swift
```

`guest.py` compiles the manifest with the `AppManifest` library and runs it
sandboxed. It checks the manifest against the app's contracts, its
`resources/<language>.lproj/Manifest.strings` and the slices' minimum OS
versions. It writes the portable `Info.plist` keys, and embeds the manifest
in every slice's `rt.manifest` section. Without a manifest, flags describe
the app:

```sh
Scripts/build-bundle.sh --product ExampleApp --id org.pureswift.example \
    --name Example --version 1.0 --build 1 --capability bluetooth
```

The scripts' own tests:

```sh
python3 -m unittest discover -s Scripts -p 'test_*.py'
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

`RuntimeWasmTests` (in `Packages/RuntimeWasm`) runs the example app's
`App.wasm` when it has been built (`Scripts/build-wasm.sh ExampleApp`), the
same app `DynamicRuntimeTests` runs as a native slice.

### Linking a slice into a host

A host links the app's `libapp.a` next to its own Swift code. The slice
defines `rt_dispatch` and `rt_finalize`, so the host depends on AppRuntime
without the `GuestExports` trait, and binds its own `DynamicRuntime` to the
runtime directly:

```swift
.package(url: "https://github.com/PureSwift/AppRuntime.git", from: "…", traits: [])
```

```swift
let native = NativeRuntime.shared
native.bindDirectly()
MyContractProxy.register(MyImplementation.self, in: native)
native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)
```

The app's calls arrive through the `rt_*` C symbols; the host's proxies and
exports never use them. `Packages/LinkedSlice` tests this with the example
app's macOS slice:

```sh
Scripts/guest.py slice --product ExampleApp --target macos
cd Packages/LinkedSlice
swift test
```

### wasm2c: App.wasm as a slice

A host with no slice for its platform translates `App.wasm` to C with
WABT's wasm2c (`brew install wabt`). `Scripts/wasm2c-shim.py` adds the
import shim and a minimal WASI, and seals the result into a `libapp.a` that
a host links exactly like a slice:

```sh
Scripts/build-wasm.sh ExampleApp
Scripts/wasm2c-shim.py build --wasm .build/guest/ExampleApp/wasm32/App.wasm \
    --output .build/guest/ExampleApp/wasm2c
cd Packages/LinkedSlice
APPRUNTIME_LINKED_ENGINE=wasm2c swift test
```

`APPRUNTIME_LINKED_PRODUCT=ExampleUI` runs the example UI app instead,
either way.

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
