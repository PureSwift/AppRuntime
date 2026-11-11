# DynamicRuntime — Design

**Status:** Draft
**Working name:** DynamicRuntime (after the `@DynamicRuntime` macro)

A portable app runtime: apps are written once in **Embedded Swift**, compiled to **wasm32**, and run inside a native host on iOS, macOS, Android, and Linux. The guest talks to the platform through a small **dynamic-runtime C ABI** (`rt.h`) modeled on the Objective-C runtime and reduced to what Objective-C, JNI, and plain C all support. Each platform supplies native implementations of portable **contracts** written in Swift.

---

## 1. Goals and non-goals

### Goals
- One Swift source tree, one `.wasm` module, many platforms; the same source also compiles natively against the same ABI.
- Call native platform functionality (Bluetooth, camera, UI, …) with no per-platform code in the app.
- A host ABI small enough to implement against the Objective-C runtime, JNI, a C function table, or native Swift.
- Guest code is always Embedded Swift; hosts may be written in any language.
- App bundles contain **only guest code**. The engine, runtime core, backends and renderers belong to the host, so apps and hosts update independently.
- No JIT anywhere, so it is valid on iOS.
- One portable app manifest that generates Info.plist, AndroidManifest.xml, and the Linux bundle metadata.
- Mismatches (missing implementations, undeclared permissions) fail at build or load time, not mid-run.

### Non-goals
- Downloading or hot-updating guest code in App Store builds (see §14).
- Exposing every feature of every native runtime. The core ABI is the **intersection**; extras live in platform-specific layers.
- Multi-threaded guests (v1 is single-threaded, on the main thread).
- wasm64 (see §13).

---

## 2. Architecture

Apps target one C ABI (`rt.h`) and can be compiled **either to wasm32 or natively**. The runtime core (handle table, contract registry, marshaler, backends, renderers) is the same in both modes. Only the thin layer that connects the app to the core differs.

```
            App source (Swift, contracts, SwiftUI frontend) — identical
                     │                              │
          ┌──────────┴──────────┐        ┌──────────┴──────────┐
          │ wasm32 build        │        │ native build        │
          │ rt_* = wasm imports │        │ rt_* = C symbols    │
          └──────────┬──────────┘        └──────────┬──────────┘
                     │                              │
          ┌──────────┴──────────┐                   │
          │ engine: WasmKit     │                   │
          │   or wasm2c (AOT)   │                   │
          │ + import shim       │                   │
          │ (offset → pointer)  │                   │
          └──────────┬──────────┘                   │
                     └──────────────┬───────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────┐
│ Runtime core (shared)                                        │
│   handle table · contract registry · marshaler · validation  │
│   backends:  ObjC runtime │ JNI │ Swift registry │ C table   │
│   renderers: Compose │ SwiftUI │ UIKit (iOS 6) │ SDL3 │ DOM  │
├──────────────────────────────────────────────────────────────┤
│ Platform: UIKit/AppKit/CoreBluetooth │ Android SDK │ SDL3/BlueZ │
└──────────────────────────────────────────────────────────────┘
```

Layers:

1. **Runtime ABI (`rt.h`)**: about 15 functions, the same on every platform and in both compilation modes. Stable and versioned.
2. **Contracts**: portable Swift protocols (`@DynamicRuntime`) implemented natively per platform. This is the main way apps use the platform.
3. **Platform bindings** (optional): bindings generated from native SDKs (iOS headers, android.jar, SDL headers) for platform-specific code. They use the same ABI with native lookup keys.
4. **Portable UI** (optional): Embedded SwiftUI frontend in the guest, emitting a render IR to per-platform players (§9).

### 2.1 Compilation modes

| Mode | App binary | `rt_*` linkage | Engine | Typical use |
|---|---|---|---|---|
| **wasm, interpreted** | `App.wasm` | wasm imports → shim → core | WasmKit | build-once distribution, hot reload, shared runtime on Linux, browser |
| **wasm, AOT** | `App.wasm`, translated by the host's packager with wasm2c | direct C calls to the shim | none at runtime | iOS packaging (no JIT); armv7 without Embedded-Swift ABI workarounds |
| **native** | static library (`.a`) per target, linked by the host | direct C calls to the core | none | debugging with lldb, maximum performance, Android via JNI |

All three link the same runtime core, so contracts, handles, renderer IR, manifest and validation behave identically.

### 2.2 How each side links

**rt imports (app → runtime).** `rt.h` switches on `__wasm__` (see Appendix A):
- wasm32: `import_module("rt")` imports. The host's **import shim** converts guest offsets to native pointers (`memory base + offset`, bounds-checked) and calls the core's `rt_*` functions.
- native: plain `extern` symbols exported by the runtime library.

**Guest exports (runtime → app).** `rt_dispatch` and `rt_finalize`:
- wasm32: module exports, called through the engine.
- native: ordinary symbols defined by the app and resolved at link time.
- armv7 iOS native builds: calls from the runtime into Embedded Swift code go through stack realignment (`objcrt_call_aligned` in Swift-iOS6). The wasm and wasm2c modes don't need this, because wasm2c output is plain C compiled for the iOS ABI.

**Swift side.** The macros expand to calls into a C module (`CRuntime`) that imports `rt.h`. Nothing in the expansion depends on the mode, so the same `@DynamicRuntime` source builds for both.

### 2.3 Per-platform native mode

The app's native slice is a static library. The **host** owns `main`, links the slice with its own code, and produces the runnable artifact:

| Platform | Host links | Host code | Entry |
|---|---|---|---|
| iOS / macOS | `libapp.a` + host runtime (static) → app executable, at packaging time | Swift / Objective-C runtime core, ObjC backend, renderer | host `main` → app's `rt_main` |
| iOS 6 (armv7) | same, with Swift-iOS6's call-in realignment shims | Objective-C / C or Embedded Swift | same |
| Android | `libapp.a` + JNI shim → `libapp.so` per ABI, at packaging time | Java / Kotlin (contracts, Compose renderer) + a small C JNI shim implementing `rt_*` | host `Activity` → `System.loadLibrary` → `JNI_OnLoad` |
| Linux (own distro) | `libapp.a` → `libapp.so` against the system `librt.so`, **at install time** | system runtime (`rt-host`, `librt.so`) | launcher → `rt-host` → `dlopen` → `rt_main` |
| Browser | n/a (wasm only) | JavaScript | — |

### 2.4 Keeping the modes equivalent

- **Guest code is Embedded Swift in both modes** (§5). There is no full-Swift build of app code or SDK libraries.
- **Handles everywhere.** Native mode uses `rt_obj` handles too, never raw `id` / `jobject` pointers. `rt_same`, retain/release and lifetime rules stay identical.
- **No retained pointers** into app memory in either mode (§6.3).
- **Integer width differs.** `Int` is 32 bits on wasm32 and 64 bits on native arm64. Contracts use explicit `Int32` / `Int64`, so the ABI is unaffected, but app logic that depends on `Int` overflow must be tested in both modes.
- **Single-threaded in both modes**, even though native could allow more.
- **Metadata in both formats.** The macros emit contract, class and manifest metadata into a wasm custom section (wasm32) or an object-file section (native: `__DATA,__rt_contracts` / `.rt_contracts`, via Swift's section-placement attributes). The packager and runtime read either and run the same validation (§10).
- **Capability enforcement is advisory in native mode.** Native code could call `objc_msgSend` or JNI directly and skip the runtime. Packager validation still applies; the runtime-side refusal is only binding in wasm mode.

### 2.5 Bundle contents

An app is distributed as one **universal bundle** carrying a slice per target (wasm32 plus any native targets) and thinned when installed or packaged. See §7.5–§7.7.

---

## 3. The runtime ABI

The full header is in Appendix A. Summary:

| Import | Purpose |
|---|---|
| `rt_class(name)` | Resolve a contract name (portable) or a native class name |
| `rt_method(cls, name, sig, flags)` | Resolve a method: instance, static, or constructor |
| `rt_call(target, method, args, ret)` | Invoke a method |
| `rt_retain` / `rt_release` | Reference counting on handles |
| `rt_same` / `rt_is_instance` | Identity and type tests |
| `rt_string_new` / `rt_string_utf8` | Strings, copied in and out of the guest |
| `rt_bytes_new` / `rt_bytes_read` | Byte buffers, copied in and out |
| `rt_implement(interfaces, methods, context)` | Native object whose methods call back into the guest |
| `rt_error_message` | Message for the last thrown error |

| Export (guest) | Purpose |
|---|---|
| `rt_main()` | Entry point, called once by the host after loading; the app sets up and returns |
| `rt_dispatch(context, index, self, args, ret)` | Native code calling a guest-implemented method |
| `rt_finalize(context)` | Native object from `rt_implement` was destroyed |

### 3.1 Wire types

```
sig  := '(' arg* ')' ret
arg  := 'Z' | 'I' | 'J' | 'F' | 'D' | 'O'
ret  := arg | 'V'
```

| Code | Wire type | Notes |
|---|---|---|
| `Z` | bool | host narrows to `BOOL`/`bool`/`jboolean` |
| `I` | int32 | host narrows to char/short/byte where native |
| `J` | int64 | host narrows to 32-bit `NSInteger` on armv7 |
| `F` | float32 | |
| `D` | float64 | host narrows to 32-bit `CGFloat` on armv7 |
| `O` | object handle | nullable |

Each scalar uses one 8-byte slot. Native structs (`CGRect`, …) are **flattened** to one slot per scalar field. Backends without structs (JNI) never see them.

The host reads the **native** signature at runtime (`method_getTypeEncoding`, the JNI descriptor, the C table) and converts the wire values to it. This lets one `.wasm` run on arm64 and armv7, where `NSInteger`, `CGFloat`, and `BOOL` have different sizes.

### 3.2 What the core leaves out, and why

These are left out because at least one of ObjC, JNI, or C lacks them:

| Feature | Missing on |
|---|---|
| Runtime subclassing of concrete classes | JNI (would need dex generated at runtime) |
| Fields / ivars as a separate concept | ObjC uses methods (properties) |
| Weak references | plain C |
| Structs as values | Java |
| Unsigned / 8-bit / 16-bit integers | Java (no unsigned) |
| Varargs | JNI, and not portable through libffi |
| Collections other than bytes | not shared in a usable form |
| Method overloading in contracts | ObjC |
| Stable handle identity | JNI (no stable identity key) |

Backend-specific layers may add imports on top of the core.

---

### 3.3 WASI preview 1

**Decision:** wasm guests may import **WASI preview 1** (`wasi_snapshot_preview1`) in addition to `rt`. Preview 1 is frozen, so it fits the stable-ABI goal, and it gives the Swift stdlib its basics (stdout/stderr, clocks, random, args/environ, `proc_exit`).

- **File access** is limited to preopened directories mapped to the app's container (plus a read-only preopen of the bundle's resources). Nothing outside them is visible.
- **No sockets.** Networking goes through contracts.
- **Hosts:** WasmKit's WASI bridge (iOS, macOS, Linux, Android), wasm2c with a small WASI shim (iOS packaging), a JS shim in the browser.
- **Native builds** use the platform libc for the same functionality. On the Linux distro, Landlock confines file access to the same container directories, so both modes see the same files.

## 4. Contracts

A contract is a Swift protocol that marks a portable API. The guest calls it, and each platform registers an implementation.

```swift
@DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
protocol Central {
    static func make(_ delegate: CentralDelegate) -> Self
    func state() -> Int32
    func scan(services: [String], allowDuplicates: Bool)
    func stopScan()
    func connect(_ peripheral: Peripheral)
    func disconnect(_ peripheral: Peripheral)
}

@DynamicCallback("org.pureswift.bluetooth.CentralDelegate")
protocol CentralDelegate {
    func didUpdateState(_ central: Central)
    func didDiscover(_ peripheral: Peripheral, advertisement: Advertisement, rssi: Int32)
    func didConnect(_ peripheral: Peripheral)
    func didFailToConnect(_ peripheral: Peripheral, error: Int32)
    func didDisconnect(_ peripheral: Peripheral, error: Int32)
}
```

A protocol is the source of truth because it:
- can be declared without method bodies, so it doesn't depend on function body macros;
- gives native Swift implementations something to conform to;
- can be parsed by a build plugin to generate Java, ObjC, and C contracts.

### 4.1 Contract rules (checked by the macro)

- Parameter and return types are limited to: `Bool`, `Int32`, `Int64`, `Float`, `Double`, `String`, `[UInt8]`, other contracts, callback protocols, `Optional` of object types, and **arrays** of `String`, contracts or callbacks. Arrays travel as the built-in `List` contract (§7.4); `[UInt8]` stays a byte buffer.
- No overloads (name plus arity must be unique).
- No generics, no structs, no varargs.
- `throws` is allowed.
- Each contract has a version. Later versions may only **add** methods.

### 4.2 Macro expansion

The same contract file compiles in two contexts:

**Guest (Embedded Swift, wasm32):** generates `final class CentralProxy: Central`
- caches `rt_class` / `rt_method` lookups in globals, resolved lazily;
- each method marshals its arguments into slots, then calls `rt_call` and unmarshals the result;
- `deinit` calls `rt_release`;
- callback parameters are wrapped with `rt_implement`, and a generated `rt_dispatch` switch routes back into Swift;
- writes contract metadata into a wasm custom section (§10).

**Host (native Swift):** generates a registration adapter, so a native type conforming to `Central` can be registered under the contract name with the Swift backend.

### 4.3 Generated contracts for other languages

A SwiftPM build plugin parses contract declarations and emits:

| Swift | Java (interface) | ObjC (`@protocol`) | C header |
|---|---|---|---|
| `Bool` / `Int32` / `Int64` / `Float` / `Double` | `boolean` / `int` / `long` / `float` / `double` | `BOOL` / `int32_t` / `int64_t` / `float` / `double` | same as ObjC |
| `String` | `String` | `NSString *` | `rt_obj` |
| `[UInt8]` | `byte[]` | `NSData *` | `rt_obj` |
| contract / callback | generated interface | generated protocol | `rt_obj` |
| `throws` | `throws Exception` | trailing `error:(NSError **)` | status return |

Method key mapping (portable key `connect:timeout:`):
- Java: method `connect`, resolved by name and arity on the implementing class
- ObjC: `-connect:timeout:error:` (the `error:` suffix appears only when the method `throws`)
- Swift / C: registry entry under the portable key

---

### 4.4 Contracts are object models, not RPC

**Rule:** a contract is designed like a native object-oriented API (objects, methods, delegates), using only the dynamic object runtime. There are no per-subsystem C ABIs, request IDs, or hand-packed byte formats.

- **Objects stand for things.** Peripherals, services, characteristics and advertisements are contract objects (`rt_obj` handles), not strings or integer IDs.
- **Delegates deliver results.** A delegate method carries the object it's about (`didUpdateValue(peripheral, characteristic, value, error)`), the way CoreBluetooth's and Android's own APIs do, so nothing has to match request IDs.
- **Structured data is objects with getters**, plus `List` for collections and `[UInt8]` only for data that is bytes by nature (a characteristic value, manufacturer data).
- **Host obligations stay the same as any native SDK's:** queue operations the platform can't run concurrently (Android's `BluetoothGatt` runs one operation per device at a time), report a failure when a target disappears, and call every delegate on the main thread.

Example, continuing `Central` above:

```swift
@DynamicRuntime("org.pureswift.bluetooth.Peripheral")
protocol Peripheral {
    func identifier() -> String
    func name() -> String?
    func setDelegate(_ delegate: PeripheralDelegate)
    func discoverServices(_ uuids: [String])
    func services() -> [Service]
    func discoverCharacteristics(_ uuids: [String], for service: Service)
    func readValue(_ characteristic: Characteristic)
    func writeValue(_ value: [UInt8], for characteristic: Characteristic, withResponse: Bool)
    func setNotifyValue(_ enabled: Bool, for characteristic: Characteristic)
}

@DynamicCallback("org.pureswift.bluetooth.PeripheralDelegate")
protocol PeripheralDelegate {
    func didDiscoverServices(_ peripheral: Peripheral, error: Int32)
    func didDiscoverCharacteristics(_ peripheral: Peripheral, service: Service, error: Int32)
    func didUpdateValue(_ peripheral: Peripheral, characteristic: Characteristic, value: [UInt8], error: Int32)
    func didWriteValue(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)
    func didUpdateNotificationState(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)
}

@DynamicRuntime("org.pureswift.bluetooth.Service")
protocol Service {
    func uuid() -> String
    func isPrimary() -> Bool
    func characteristics() -> [Characteristic]
}

@DynamicRuntime("org.pureswift.bluetooth.Characteristic")
protocol Characteristic {
    func uuid() -> String
    func properties() -> Int32
}

@DynamicRuntime("org.pureswift.bluetooth.Advertisement")
protocol Advertisement {
    func localName() -> String?
    func manufacturerData() -> [UInt8]?
    func serviceUUIDs() -> [String]
    func serviceData(_ uuid: String) -> [UInt8]?
    func txPowerLevel() -> Int32      // Int32.min if absent
    func isConnectable() -> Int32     // -1 unknown, 0, 1
}
```

Each platform implements this as a thin wrapper over its own object model:

| Platform | Implementation |
|---|---|
| iOS / macOS | `CBCentralManager` / `CBPeripheral` / `CBService` / `CBCharacteristic`, with the contract delegates forwarding CoreBluetooth's (Objective-C or Swift) |
| Android | `BluetoothLeScanner` + `BluetoothGatt`, with `ScanCallback` / `BluetoothGattCallback` forwarding to the contract delegates (Java/Kotlin) |
| Linux distro | BluetoothLinux (HCI) or BlueZ D-Bus objects (Swift / C) |

**Guest side:** a small adapter implements PureSwift GATT's async `CentralManager` on top of these contracts. Operations await a continuation keyed by `(peripheral, characteristic)`, and `scan` / `notify` return streams fed by the delegates. App code uses `CentralManager` unchanged everywhere. This is the shape of SwiftUI-iOS9's `DarwinCentral`, minus its C header.

## 5. Guest code: Embedded Swift

**Decision:** all guest code (the app and the SDK libraries it links) is **Embedded Swift**, in every compilation mode. Hosts can be written in **any language**, because the only contract between them is the C ABI (`rt.h`) plus WASI preview 1 and GLES.

### 5.1 Toolchain and targets

**Toolchain:** Swift **6.4** (swift.org release, matching Swift SDK for Wasm), pinned for all guest builds and SDK libraries. Moving to a newer toolchain is a deliberate SDK release, never a silent upgrade.

| Mode / platform | Guest build |
|---|---|
| wasm32 (all hosts) | Embedded Swift for `wasm32-unknown-wasip1`, using wasi-libc |
| iOS / macOS native (arm64) | Embedded Swift for the Apple triple → `libapp.a` |
| iOS 6 native (armv7) | Embedded Swift for `armv7-apple-none-macho`, with Swift-iOS6's setup (`-marm -ffixed-r9`, rebuilt concurrency runtime) → `libapp.a` |
| Android native | Embedded Swift for a freestanding ELF triple per ABI (arm64-v8a, armeabi-v7a, x86_64) → `libapp.a` (PIC, libc-agnostic) |
| Linux distro native | Embedded Swift for a freestanding ELF triple per arch → `libapp.a` (PIC, libc-agnostic; §7.5) |

Each library is built **once per target, in one language mode**. There's no full-Swift build of the SDK.

### 5.2 Language subset

| Available | Not available |
|---|---|
| structs, enums with payloads, classes, generics (fully specialized), closures | Foundation, ICU, Formatters, networking libraries (use contracts) |
| `String` (Unicode data linked only when needed), `Array`, `Dictionary`, `Set`, `Optional`, `Result` | `Codable` |
| protocols used as generic constraints; class-bound existentials | `Mirror` and runtime type metadata / reflection |
| `ForEach` over ranges or `Identifiable` data | **key paths** (SwiftUI-iOS9 lists them as unavailable with Swift 6.4.2), so no `ForEach(_:id:)` with a key path; `any P` existentials of non-class protocols |
| `async`/`await` with a single-threaded executor | multi-threaded guest code |
| macros (they run at build time on the host machine) | `@objc`, ObjC or Java interop in the language itself (the runtime does that) |

Third-party packages must compile in Embedded mode. Binary size stays in the kilobytes-to-hundreds-of-kilobytes range; full-Swift's ~5–8 MB per-app stdlib floor never applies.

### 5.3 Observation

Guests use `@Observable` / `@Bindable` with Apple's source API.

- **Bindings without key paths:** Apple's `@Bindable` uses `@dynamicMemberLookup` over `ReferenceWritableKeyPath`, which isn't available on 6.4. Instead, `@Observable` also generates a nested `Bindings` struct with one `Binding` per stored property, and `@Bindable`'s `projectedValue` returns it. `$model.name` keeps working at the call site.

- **Upstream:** the Swift Forums pitch "Observation performance and modeling improvements" (Oct 2026) proposes building the `Observation` module for Embedded Swift with **index-only** registrar entry points: `access(propertyIndex:)`, `willSet(propertyIndex:)`, `didSet(propertyIndex:)`, `withMutation(propertyIndex:_:)`. In Embedded mode the property index is the property's identity, and key-path-only features (`Event.matches(_:)`, key-path entry points, `Codable` registrar) don't exist.
- **Until it ships:** the SDK includes a **stopgap `Observation` module whose API matches the pitch exactly**, so app code compiles unchanged when the toolchain module replaces it:
  - `@Observable` expands stored properties to `access(propertyIndex:)` / `withMutation(propertyIndex:_:)` with indices assigned at macro time; `@ObservationIgnored` excludes a property.
  - `ObservationRegistrar` is a final class with a 64-bit `observedMask` fast path: an unobserved property's write skips the observer table. Indices of 64 or more use the slow path.
  - `withObservationTracking` uses a global tracking stack, since the guest is single-threaded. No locks or atomics.
  - `ObservationTracking.Listener`-style persistent listeners with a coalescing option.
- **Rules for SDK code:** never depend on `Event.matches(_:)`; treat a change notification as "this view is dirty".
- `ObservableObject` / `@Published` stay supported (Swift-iOS6 already implements them in Embedded) for code ported from older SwiftUI.
- `@ObservationDerived` (derived state) is adopted once the pitch settles its design.

### 5.4 Concurrency

`async`/`await` and `AsyncStream` are guest-side sugar over delegate contracts (§6.2.1). The Embedded concurrency runtime (`libswift_Concurrency.a`) assumes a single thread, which matches the guest model.

**Executor:** the guest **replaces the default cooperative executor**. Its drain loop never returns, and under WASI it would block the host thread while waiting on sleeps. The replacement (`GuestExecutor` in `DynamicRuntime`):

- **Immediate jobs:** queued inside the guest and drained just before control returns to the host: when `rt_main` (through `Runtime.main`), `rt_dispatch` or `rt_finalize` returns. The host never blocks waiting on a task. A call that re-enters the guest while a job runs (guest → host → guest) doesn't drain, so jobs never interleave.
- **Sleeping:** Embedded Swift 6.4 has no clocks and no `Task.sleep`, so guests call `RuntimeClock.sleep(nanoseconds:)`. It suspends on a continuation, schedules a timer through the built-in `Clock` contract (§7.4) and throws `CancellationError` if the task is cancelled first. The timer fires through `rt_dispatch`, which resumes the task and drains.
- **Delayed jobs** (the runtime's delay hook): scheduled through the same `Clock` contract.
- **Deadline jobs:** without clocks there's nothing to set a deadline with, so the executor treats them as immediate.
- **Main actor:** the main executor and the global executor are the same queue.

The hooks are the Embedded runtime's `swift_task_enqueueGlobalImpl` family (`swift/ExecutorImpl.h`), written in Swift with `@_silgen_name`, the same set Swift-iOS6's `Executor.c` defines. They're compiled only for Embedded builds; in host tests, Swift's own executor runs guest code.

**Per mode:**

| Mode | Executor implementation |
|---|---|
| wasm32 | `GuestExecutor`. The wasm runtime defines the isolation checks itself. Build for `wasm32-unknown-wasip1`, not `-threads`. |
| native (Apple, armv7 and x86_64 ELF) | `GuestExecutor`, plus the isolation-check hooks. The prebuilt runtime's few libc calls outside §7.5 (fatal-error printing, the cooperative executor's sleep), and Swift functions that only a dead-stripping link removes, are sealed in privately (`Scripts/support/concurrency.c`). iOS 6 still needs the Thumb-bit fixup for the prebuilt runtime, a host job. |
| native `aarch64-none-none-elf` (`linux-arm64`, `android-arm64-v8a`) | none yet: the toolchain ships no `_Concurrency` module or runtime for the triple, so these slices are built without concurrency (`EMBEDDED_NO_CONCURRENCY`). Linux toolchains ship one for `aarch64-unknown-linux-gnu`. |

### 5.5 Host languages

The Embedded requirement applies only to the guest. Hosts and contract implementations use whatever each platform does best:

| Host part | Languages |
|---|---|
| Runtime core (handle table, registry, marshaler) | Swift (full, Foundation allowed), C, or Objective-C |
| Apple contract implementations | full Swift, Objective-C (CoreBluetooth, CoreLocation, … with all of Foundation) |
| iOS 6 host | Objective-C / C, or Embedded Swift (there's no Swift runtime on iOS 6) |
| Android | Kotlin / Java (contracts, Compose renderer) + C or Swift for `librt.so` and JNI |
| Linux distro | C or Swift for `librt.so`; any language for system services behind contracts |
| Browser | JavaScript / TypeScript |

---

## 6. Backends

| Op | ObjC | JNI | Swift registry | C table |
|---|---|---|---|---|
| `rt_class` | registry → `objc_getClass` | registry → `FindClass` → global ref | registry | registry |
| `rt_method` | `sel_registerName` + check encoding | `GetMethodID` / `GetStaticMethodID` | closure lookup | fn pointer lookup |
| `rt_call` | `objc_msgSend` / `_stret` via libffi | `Call<T>MethodA` with a `jvalue[]` array | closure call | direct call |
| ctor | `alloc` + `init…` | `NewObjectA` with `<init>` | `make()` | constructor fn |
| retain/release | `objc_retain` / `objc_release` | refcounted global ref | Swift ARC | refcount + destroy fn |
| `rt_implement` | runtime class conforming to protocols; IMPs forward | `java.lang.reflect.Proxy` | adapter object | fn ptr + userdata |
| errors | `@try` / `NSError` at the boundary | `ExceptionCheck` after every call | Swift `throws` | status code |

### 6.1 Platform implementations (example: Bluetooth Central)

| Platform | Implementation |
|---|---|
| iOS / macOS | Swift over CoreBluetooth (Swift backend), or ObjC class (ObjC backend) |
| Android | Java class implementing the generated interface over `BluetoothLeScanner` (JNI backend), or host Swift via swift-java |
| Linux | Swift over BluetoothLinux (Swift backend) |
| C libraries (SDL3, …) | C function table |

### 6.2 Callbacks and subclassing

- **Core:** `rt_implement` covers interfaces and protocols: delegates, listeners, C callbacks.
- **ObjC without JIT:** either IMP = `_objc_msgForward` with a shared `forwardInvocation:` that calls `rt_dispatch`, or libffi closures (static trampolines on iOS).
- **Subclassing concrete classes** (`UIViewController`, `Activity`, `View`) is a platform-layer feature, not core:
  - ObjC: `objc_allocateClassPair` at startup, driven by metadata in the custom section.
  - Android: Java stub classes generated at build time with `native` methods forwarding to the bridge (the same approach as NativeScript's static binding generator and Xamarin's Android Callable Wrappers).

### 6.2.1 Delegates are the contract model; async is guest-side sugar

**Decision:** contracts use delegates (`@DynamicCallback` protocols) only. Contracts have no `async` methods or streams, and native implementers only implement methods plus delegate callbacks.

Swift concurrency is a convenience layer that exists **only in the guest**, built on top of delegate contracts:

- **One-shot result** → an extension wraps the call plus its delegate callback in `withCheckedThrowingContinuation` / `withTaskCancellationHandler`.
- **Event sequence** (scan results, location updates) → an extension returns an `AsyncThrowingStream`. The stream's internal delegate yields values, and `onTermination` calls the contract's stop/cancel method.
- These wrappers can be hand-written or generated by a separate opt-in macro. Either way they're outside the ABI and contract metadata, and native backends never see them.

Why:
- One callback model for every backend. Java, ObjC, Swift and C implementations all look the same.
- Synchronous native→guest requests (data sources, `should…` methods) need delegates anyway, so delegates are required regardless.
- No dependency on Embedded Swift concurrency or a guest executor in the core. Apps that use the async layer get `GuestExecutor` (§5.4), a single-threaded executor that runs its jobs before returning from `rt_dispatch`.
- Timers for `RuntimeClock.sleep` come from a built-in `Clock` contract (`now()`, `after(nanoseconds, delegate)`), also delegate-based.

### 6.3 Object handles and memory

- A handle is a strong reference: a retain on ObjC, a global ref on JNI.
- Returned objects are +1. Arguments passed into `rt_dispatch` are borrowed (+0).
- Handles are not unique per object, so compare with `rt_same`.
- ObjC methods in the alloc/new/copy/mutableCopy families are normalized to +1 by the host. All other returns are retained when they enter the handle table.
- The host wraps every host→guest entry in an `@autoreleasepool`.
- **Cycles:** guest → Java → guest cycles leak, because Java's GC can't see through global refs. Back-references from native objects to the guest (delegates) must be unowned. The native object created by `rt_implement` owns its guest context and releases it through `rt_finalize`.
- The host never keeps pointers into guest linear memory after a call returns, because `memory.grow` can move the memory base.

### 6.4 Threading

- One guest instance runs on the main/UI thread.
- The host moves every callback (GCD, Binder threads, SDL events) onto the main thread before entering the guest.
- JNI: cache the `JNIEnv` per thread and attach threads as needed.

---

## 7. App bundles, manifest and capabilities

### 7.1 Portable manifest

```swift
// App.swift — read by the build plugin
let app = App(
    id: "org.pureswift.blescanner",
    name: .localized("app.name"),
    version: "1.4.0", build: 42,            // integer: Android versionCode
    languages: ["en", "es"],
    executable: "BLEScanner",
    targets: [.wasm32, .ios(.arm64, .armv7), .macos, .linux(.arm64, .armv7, .x86_64), .android(.arm64, .armv7)],   // missing native slices are filled by wasm2c
    capabilities: [
        .bluetooth(usage: .localized("perm.bluetooth")),
        .location(.whenInUse, usage: .localized("perm.location")),
    ],
    platforms: [
        .iOS("15.0"), .macOS("12.0"),
        .android(minSDK: 26, targetSDK: 35),
        .linux,
    ]
)
```

The manifest only has fields that exist on every platform. Platform-only settings go in escape hatches (`.iOS(extraInfoPlist:)`, `.android(extraManifest:)`).

### 7.2 Generated outputs

| Field | iOS / macOS `Info.plist` | Android manifest + resources | Linux `.app` bundle |
|---|---|---|---|
| id | `CFBundleIdentifier` | `applicationId` | `CFBundleIdentifier` |
| name | `CFBundleDisplayName` + `InfoPlist.strings` | `@string/app_name` | `CFBundleDisplayName` + `.lproj` |
| version / build | `CFBundleShortVersionString` / `CFBundleVersion` | `versionName` / `versionCode` | same as Apple |
| languages | `CFBundleLocalizations`, `.lproj` | `res/values-xx/`, `locales_config.xml` | `.lproj` |
| min OS | `MinimumOSVersion` / `LSMinimumSystemVersion` | `minSdk` / `targetSdk` | n/a |
| permission text | `NS…UsageDescription` (localized) | `strings.xml` for rationale UI | bundle keys shown by the runtime |
| icon | asset catalog | `mipmap-*` | bundle icon |
| entitlements | `.entitlements` (push, HealthKit, App Groups, …) | n/a | runtime-defined |

### 7.3 Capabilities from contracts

Contracts declare the capabilities they need (`requires: .bluetooth`). The guest's custom section lists every contract the module uses. At packaging time:

- **contract used but capability not declared:** build error (iOS kills the app the first time it touches the API without the usage string);
- **capability declared but unused:** warning (unused permissions are a common App Review rejection);
- **at runtime:** the host refuses `rt_class` for contracts whose capability is missing from the manifest.

Expanding capabilities into native entries:

| Capability | iOS | Android | Linux |
|---|---|---|---|
| `.bluetooth` | `NSBluetoothAlwaysUsageDescription` | `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` (API 31+); `BLUETOOTH`, `BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION` with `maxSdkVersion="30"`; `uses-feature bluetooth_le` | HCI / BlueZ D-Bus access |
| `.camera` | `NSCameraUsageDescription` | `CAMERA` + `uses-feature camera` | `/dev/video*` |
| `.location(.whenInUse)` | `NSLocationWhenInUseUsageDescription` | `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | runtime-defined |
| `.notifications` | runtime request; push needs `aps-environment` | `POST_NOTIFICATIONS` (API 33+) | runtime-defined |

### 7.4 Built-in contracts

- **`Permissions`**: `status(capability)` and `request(capability, callback)`. It hides the difference between iOS's implicit prompts and Android's explicit `requestPermissions`.
- **`List`**: a host-owned ordered collection (`count()`, `object(at:)`, `string(at:)`, `append…`), backed by `NSArray` / `java.util.List` / a C vector. The macros convert contract parameters and results of type `[String]` / `[SomeContract]` to and from `List`, so contracts declare plain Swift arrays. It's the only collection type the runtime knows.
- **`Bundle`**: id, version, preferred languages, localized strings. The guest reads metadata through this contract and never parses platform files itself.
- **`Clock`** (`org.pureswift.runtime.Clock`): `now()`, monotonic nanoseconds, and `after(nanoseconds, delegate)`, which calls `delegate.fire()` once (`org.pureswift.runtime.ClockDelegate`) on the main thread. The host holds the delegate until it fires. It's the guest's only source of time (§5.4). `HostRuntime` serves it from a `HostClock` the host supplies (`ManualClock` for tests and self-pumped loops).

The manifest is also embedded in the `.wasm` custom section so the host can validate it at load time.


### 7.5 Universal bundle

The universal bundle is the distribution format, like an Android App Bundle. It carries the app's **guest code only**, in every form a host might want, and every host turns it into whatever its platform runs.

**What a bundle never contains:** the wasm engine, the runtime core (`librt`), contract implementations, renderers, or any other host functionality. The only interface between an app and a host is `rt.h`, WASI preview 1, GLES 2.0, the render IR and the contract versions, all add-only. So:
- a host update (new renderer, bug fixes, new contracts) reaches every installed app without rebuilding it;
- an app update never has to ship or wait for a host release, as long as the host meets the app's minimum ABI and contract versions.

Guest-side SDK libraries (the SwiftUI frontend, the Observation module, contract proxies) **are** guest code, so they're compiled into the app's slices.

**Slices:**

| Target ID | Slice |
|---|---|
| `wasm32` | `App.wasm`, a WASI **reactor** module, not a command (required; every host can use it) |
| `ios-arm64`, `ios-armv7` (iOS 6) | `libapp.a`, Mach-O objects |
| `macos` | `libapp.a`, Mach-O objects (arm64 + x86_64 in one archive allowed) |
| `linux-arm64`, `linux-armv7`, `linux-x86_64`, `linux-i386` | `libapp.a`, ELF PIC objects |
| `android-arm64-v8a`, `android-armeabi-v7a`, `android-x86_64` | `libapp.a`, ELF PIC objects |

Native slices are optional. A host without a matching slice uses `App.wasm`.

**No slice is an executable.** Both forms are libraries with the same three exports (`rt_main`, `rt_dispatch`, `rt_finalize`) and the same imports. The host always owns `main` and the run loop:
- `App.wasm` is built as a WASI reactor (`-mexec-model=reactor`): no `_start`, an `_initialize` the host calls once, then `rt_main`. It needs no link step because it's already self-contained.
- `libapp.a` is the same thing in native object form, linked by the host.
- Apps have no `@main`. The entry point is an exported `rt_main` (via `@c`), which sets up the app and returns.

**A native slice is sealed like a wasm module:**
- **One prelinked object.** The archive holds a single `ld -r` object with the guest, the SDK libraries and the Embedded Swift runtime pieces.
- **Only the guest exports stay visible:** `rt_main`, `rt_dispatch`, `rt_finalize`. Everything else, including `swift_retain` and the concurrency runtime, is localized, so a host that also contains Swift code (any toolchain version) can't collide with it.
- **Allowed undefined symbols:** `rt_*`, `gl*`, and a fixed small libc set (`malloc`, `free`, `posix_memalign`, `memcpy`, `memmove`, `memset`, `memcmp`, `abort`, `write`, clock/random). The packager rejects slices with anything else. The guest never brings its own libc; the host's libc (libSystem, bionic, musl) satisfies them.
- **libc-agnostic by construction (ELF targets):** Linux and Android slices are compiled for **freestanding ELF triples** (for example `aarch64-none-none-elf`, `armv7-none-none-eabihf`, `x86_64-unknown-none-elf`) with position-independent code. Those use the same calling conventions as Linux (AAPCS64, AAPCS hard-float, SysV), so no glibc, musl or bionic headers or assumptions get compiled in. The packager also rejects glibc-only references such as `_FORTIFY_SOURCE` `*_chk` functions, `__errno_location`/`__errno`, versioned symbols, and TLS (`__tls_get_addr`); the guest is single-threaded and has no `thread_local`. Guest code can't `import Glibc`/`Musl` anyway, because the same source must compile to wasm.
- **Metadata sections** (`rt.abi`, `rt.contracts`, `rt.manifest`, §10) are kept in the object, so a host checks compatibility before linking.

**Layout** (carried over from AppRuntime's format, generalized from `<arch>` to `<target>`):

```
<bundle-id>.app/
├── Info.plist                  generated from App.swift (§7.1); lists RTTargets
├── wasm32/App.wasm
├── lib/<target>/libapp.a       optional native slices
├── resources/                  shared; <lang>.lproj/ for localized strings
├── icon.png
└── _CodeSignature/CodeResources   per-file hashes, signed (§7.6)
```

**Validation** (from AppRuntime): `CFBundleIdentifier` and `CFBundleExecutable` are each a single safe path component (non-empty, not `.`/`..`, no `/` or NUL). All paths are relative, and symlinks resolve inside the bundle. Every target listed in `RTTargets` has its slice. Unknown keys are ignored. Resource lookups reject `..`.

**Two kinds of bundle:**
- **rt apps** (Embedded Swift guests against `rt.h`): the stable-ABI kind. Never translated.
- **Port bundles** (plain Linux programs such as the ccleste and Nanosaur 2 examples, using the distro's SDL3 etc.): Linux only, no ABI stability promise. They are the one exception to "no executables": they ship `bin/<target>/<exe>` plus private libraries under `lib/<target>/`, as in AppRuntime, and may run under box64/box86.

### 7.6 Thinning, linking and wasm2c (host side)

Choosing a slice, linking it and handling SDK compatibility are **host jobs**. The app's build only produces the bundle.

**App packaging (developer machine):**
1. Build `App.wasm` and any native `libapp.a` slices.
2. Seal and check the native slices (§7.5).
3. Sign: `CodeResources` lists a hash per file, and the signature covers that list.

**Host packaging and install:**

| Host | What it does with the bundle |
|---|---|
| iOS | takes `ios-*/libapp.a`, or runs **wasm2c** on `App.wasm` and compiles it if there's none; links it with the host runtime into the executable; writes the flat `.app` and translated `Info.plist`; signs → `.ipa`. App Store thinning applies afterward. |
| macOS | same, into `.app/Contents/MacOS/` |
| Android | links `android-*/libapp.a` with the JNI shim into `lib/<abi>/libapp.so` (or wasm2c per ABI). **Or, with no native code at all:** keeps `App.wasm` and runs it with Chicory, a pure-Java Wasm runtime whose build-time AOT turns Wasm into JVM bytecode for d8, so the host can be entirely Java/Kotlin. |
| Browser | `App.wasm` + the JavaScript host |
| Linux distro | **installer** selects a slice (§7.7), keeps `Info.plist`, `resources/` and that slice (plus `App.wasm` as a fallback by default), drops the rest, and repacks a read-only squashfs. A native slice is linked to `libapp.so` against the system `librt.so` with the distro's `ld.lld`, and the result is cached outside the bundle. |

**Independent updates on Linux:** `librt.so` is a dynamic library with versioned, add-only symbols (§2.3), so a host update needs no relink. An installed app's `libapp.so` keeps resolving against the new `librt.so`. A wasm slice depends only on the engine's imports. Signature verification checks every file still in the bundle against `CodeResources`, so thinning doesn't break it, and the cached link output is verified by its own hash.

**SDK compatibility:** before linking or loading, the host reads the slice's `rt.abi` and `rt.contracts` metadata. It refuses an app that needs a newer ABI or contract version than it provides, and resolves methods added later as absent (`rt_method == 0`).

### 7.7 Slice selection on Linux

Generalized from AppRuntime's `ArchSelector`, using the same host probing (`uname -m` mapping, AArch32 support, x86 multilib, installed box64/box86):

| Host | rt app order | Port bundle order |
|---|---|---|
| arm64 | `linux-arm64` → `linux-armv7` (needs AArch32) → `wasm32` | `linux-arm64` → `linux-armv7` → `linux-x86_64` via box64 → `linux-i386` via box86 (needs AArch32) |
| armv7 | `linux-armv7` → `wasm32` | `linux-armv7` → `linux-i386` via box86 |
| x86_64 | `linux-x86_64` → `linux-i386` (needs multilib) → `wasm32` | `linux-x86_64` → `linux-i386` |
| other | `wasm32` | native only |

A native slice is linked at install (§7.6). A `wasm32` slice runs through the system host: from the install-time AOT cache if the distro ships an AOT engine, otherwise interpreted by WasmKit. rt apps never use translators, because an x86 guest would need an x86 `librt.so`.

### 7.8 Linux launcher and sandbox

Carried over from AppRuntime's `bundle-runtime` and its sandbox design, which is reused nearly unchanged:

- **Filesystem view:** `/app` (bundle, read-only), `/data` (container, read-write), private `/tmp` with `XDG_RUNTIME_DIR`, OS directories read-only, own `/proc`, tmpfs `/dev` with only capability-gated nodes. Entered through `pivot_root`, with the old root detached.
- **Sequence:** cgroup v2 limits before fork → container → unshare (mount, UTS, IPC, PID, cgroup; network unless the `network` capability is declared) → fork, with the supervisor dropping to the app uid → build root → devices → service sockets → `pivot_root` → `no_new_privs`, uid/gid drop, empty bounding set, **verified** by asserting `setuid(0)` fails → seccomp last (with an architecture check that kills on mismatch) → `clearenv` → `chdir /app` → exec.
- **Per-app uids** from a persistent id→uid map, not a hash (a hash of 10,000 slots has a ~50 % collision chance at ~118 apps). Unprivileged user-namespace mode is for development.
- **What changes for rt apps:**
  - The launcher execs the **system host** (`rt-host`) inside the sandbox. A native slice's install-time `libapp.so` is `dlopen`ed against `librt.so`; a wasm slice runs in the engine. WASI preopens map to `/data` and `/app/resources` (§3.3). The bundle contributes no host code.
  - **Capabilities come from the manifest's contract capabilities** (§7.3), enforced twice: `rt_class` gating in the host, and the sandbox's device/socket exposure.
  - **Bluetooth becomes enforceable** (it's "reserved, unenforced" in AppRuntime): apps never get HCI device nodes. The Bluetooth contract's Linux backend talks to BlueZ over D-Bus, and the system bus socket is bound into the sandbox only with the `bluetooth` capability, under a D-Bus policy limited to `org.bluez`.
  - **Additions:** bundle signature verification between resolve and launch, which AppRuntime lacks; Landlock as an extra file-access layer; and a move from the seccomp denylist toward an allowlist for rt apps, whose syscall surface is small and known.
- **Packaging:** zstd squashfs images, and the self-executing polyglot form for development or plain-Linux use (unsandboxed, as in AppRuntime). The C shim (namespaces, mounts, `pivot_root`, seccomp) and the CMake/Buildroot build carry over.
- **Status:** AppRuntime's sandbox is logic-tested but not yet verified on hardware. Its checklist (`ls /`, `id -u`, `ip link`, a denied `mount`, cgroup limits) becomes the launcher's acceptance test.

---

## 8. Graphics: OpenGL ES 2.0 with WebGL 1 rules

**Decision:** the guaranteed graphics API is **OpenGL ES 2.0, restricted to what WebGL 1 allows**. It's the only API every host supports.

| Host | Provides GLES 2.0 through |
|---|---|
| iOS 6 (iPod touch 4, no ES 3.0) | native EAGL + GLES 2.0 |
| iOS / macOS (current) | native GL ES (deprecated since 2018, still shipping), or ANGLE on Metal |
| Android | EGL + GLES 2/3 |
| Linux (own distro) | Mesa EGL + GLES |
| Browser | WebGL 1 |

Vulkan and Metal have no common subset across these hosts, so neither is part of the baseline.

### 8.1 API surface

- GL is a C API, so it's exposed as **direct wasm imports** (module `env.gl`) with standard `gl*` names and types. It doesn't go through `rt_call`.
- GL object names are already integers, so they don't use the rt handle table.
- **WebGL 1 rules apply** (Emscripten's GLES2→WebGL mapping is the reference for edge cases):
  - No client-side vertex arrays: `glVertexAttribPointer` takes VBO offsets only.
  - No `glMapBuffer` / `glMapBufferRange`.
  - Copy-in and copy-out calls (`glBufferData`, `glBufferSubData`, `glTexImage2D`, `glTexSubImage2D`, `glShaderSource`, `glReadPixels`) translate guest offsets to `memory base + offset` only while the call runs. This is the same no-retained-pointer rule as §6.3.
  - Shaders are GLSL ES 1.00 with explicit precision qualifiers.
  - Extensions are queried with `glGetString(GL_EXTENSIONS)` and are never assumed.

### 8.2 Surface and frame loop

- The host owns context creation (EAGL, EGL, or a WebGL canvas).
- The guest places a `GLSurface` node in the renderer IR. Its delegate receives:
  - `frame(timestamp, width, height)`, driven by `CADisplayLink`, `Choreographer`, or `requestAnimationFrame`;
  - `resize(width, height)`;
  - `contextLost()` / `contextRestored()`. The guest must recreate GL objects after a restore, as in WebGL.
- The context is current only during `frame`. All GL calls run on the main thread, consistent with the single-thread rule (§6.4).

### 8.3 Capability and packaging

- The manifest declares `.graphics(.gles2)`. The packager adds `<uses-feature android:glEsVersion="0x00020000"/>` on Android and links OpenGLES / ANGLE on Apple platforms.
- The host refuses to bind `env.gl` imports when the capability isn't declared.

### 8.4 Optional tiers

Guests check for these at load time (an import module is either present or absent). They're never required.

| Tier | Import module | Available on |
|---|---|---|
| GLES 3.0 (WebGL 2 rules) | `env.gl3` | modern iOS/macOS (via ANGLE), Android, Linux, browsers |
| WebGPU (`webgpu.h`, wgpu-native / Dawn) | `env.webgpu` | modern iOS/macOS, Android, Linux, browsers; not iOS 6 |

### 8.5 Performance and future-proofing

- With wasm2c (iOS packaging), each `gl*` import compiles to a direct C call, so the import boundary costs essentially nothing.
- Under an interpreter, GL's many calls per frame can make the import boundary the bottleneck. If profiling shows that, add an **optional command buffer**: the guest encodes GL calls into linear memory and the host runs them in a single `gl_flush`. This is an optimization, not part of the baseline.
- Apple platforms: the host for modern Apple targets includes an **ANGLE-on-Metal** backend behind the same imports, so removing native GL ES wouldn't affect guests. iOS 6 keeps native GLES.

## 9. User interface (proposed)

**Status:** proposed design, building on two existing projects: PureSwift/AndroidSwiftUI (render IR + Compose interpreter) and colemancda/Swift-iOS6 (Embedded SwiftUI + UIKit backend).

### 9.1 Split

- **Guest: SwiftUI frontend.** App code does `import SwiftUI`. The frontend provides View structs, result builders, `@State`, `@Binding`, `@Environment`, Observation integration, `body` evaluation and structural identity. It does **no layout and no rendering**. Its only output is a `RenderNode` tree.
- **Host: renderer ("player").** Interprets the IR with the platform's own toolkit, owns layout, input, animation and accessibility, and sends events back.

### 9.2 Render IR

Adopted from AndroidSwiftUI's `RenderNode`:

| Field | Meaning |
|---|---|
| `type` | primitive kind (`"Text"`, `"VStack"`, `"Button"`, …) from a closed vocabulary (~40 node types) |
| `id` | structural identity path, stable across re-evaluation |
| `props` | `[String: PropValue]` (string / double / bool / int / array) |
| `modifiers` | ordered `[ModifierNode]` (~30 kinds); order is significant |
| `children` | eagerly resolved children |
| `count` | element count for lazy containers (rows fetched on demand) |

- Closures never cross the boundary. The IR carries **callback IDs**, and the guest keeps a callback registry.
- The IR uses a compact binary encoding. The vocabulary is **add-only**: a host renders an unknown node type as an empty placeholder and ignores an unknown modifier, so new guests degrade gracefully on older hosts.
- Defaults that differ between toolkits (stack spacing, padding, font sizes) are written explicitly into the IR so layout stays close across hosts.

### 9.3 Renderer contract

```swift
@DynamicRuntime("org.pureswift.ui.Renderer")
protocol Renderer {
    static func make(_ delegate: RendererDelegate) -> Self
    func apply(_ tree: [UInt8])                          // full tree
    func replaceSubtree(_ id: [UInt8], _ tree: [UInt8])  // incremental update
}

@DynamicCallback("org.pureswift.ui.RendererDelegate")
protocol RendererDelegate {
    func event(_ node: [UInt8], kind: Int32, payload: [UInt8])   // tap, edit, toggle, submit, …
    func rowCount(_ list: [UInt8]) -> Int32                      // synchronous
    func row(_ list: [UInt8], index: Int32) -> [UInt8]           // synchronous: serialized row subtree
}
```

One update is one `rt_call`. Lazy lists use the synchronous delegate calls, so the host's native recycler (RecyclerView, UICollectionView / UITableView) asks only for visible rows.

### 9.4 Players

| Host | Player | Status |
|---|---|---|
| Android | AndroidSwiftUI `:composeui` (Compose interpreter) | exists |
| iOS 6–12 | Swift-iOS6 backend (LayoutNode layout, keyed UIKit view reuse) behind an IR adapter | exists, needs adapter |
| iOS 13+ / macOS | `Render(node)` written in SwiftUI, keyed by `.id(node.id)` | new |
| Linux distro | SDL3 + Cairo renderer (or Swift-iOS6's layout engine drawing with Silica) | in progress |
| Browser | IR → DOM | later |

Layout is owned by each player. Players for toolkits without a layout system reuse Swift-iOS6's layout engine.

### 9.5 Update flow

1. The guest evaluates `body` inside an Observation listener (one coalesced listener per view) and sends the tree with `apply`.
2. The player builds native views.
3. The user taps: the player calls `event(node, .tap)` → `rt_dispatch` → the guest runs the registered callback, and state changes.
4. The listener marks the view dirty. On the next turn the guest re-evaluates only that subtree and sends `replaceSubtree`.
5. The player updates in place.

**Control sync:** the guest's state is the source of truth. A player sets a control from the IR only when the value differs from what that player last rendered, so a field being typed in, a slider being dragged, or a switch mid-toggle isn't overwritten. Swift-iOS6 already uses this rule.

### 9.6 Escape hatches

- `GLSurface` node for GLES drawing (§8.2).
- `NativeView(type:props:)` node. Each player looks up a factory by type name (map, web view, camera preview); unknown types render as placeholders.
- Everything that isn't UI goes through contracts.

### 9.7 Frontend sources

- **Swift-iOS6 SwiftUI** is already Embedded Swift (no `Mirror`, no dynamic casts, keys from tree position, typed tables). Split it at its `sui_*` seam: the frontend moves to the guest and emits IR; the backend becomes the iOS 6 player.
- **AndroidSwiftUI `SwiftUICore`** has the broader vocabulary but isn't Embedded-compatible today: `any View` existentials and `as? any View` casts, `Mirror`-based state and environment discovery, type names in identity paths, `ObjectIdentifier(T.self)` keys, Observation via `withObservationTracking`, and Foundation in a few files. Its IR, vocabulary and Kotlin interpreter are reused as-is; its evaluator logic is ported onto the Embedded frontend.

---

## 10. Module metadata sections

In wasm32 builds these are wasm custom sections. In native builds they are object-file sections with the same names and contents (`__DATA,__rt_*` on Mach-O, `.rt_*` on ELF).

| Section | Contents |
|---|---|
| `rt.abi` | rt ABI version the module was built against |
| `rt.contracts` | per contract: name, version, required capability, method keys plus wire signatures |
| `rt.classes` | guest-defined classes (platform layer): superclass, overridden methods |
| `rt.manifest` | serialized app manifest |

Load-time validation:
1. The host's ABI version must be at least the module's `rt.abi`.
2. Every contract must have a registered implementation whose version is at least the required minimum. Methods added after the implementation's version resolve to `rt_method == 0`, and the guest checks for them (like `respondsToSelector:`).
3. Every contract's capability must be in the manifest.
4. Wire signatures must match the registered implementation.

---

## 11. Hosts and engines

| Target | Engine | Notes |
|---|---|---|
| iOS 12+, macOS, Linux, Android | **WasmKit** | pure Swift, register-based interpreter, no Foundation dependency |
| Release builds (any) | **wasm2c / w2c2** → native | no interpreter cost; static, App Store friendly |
| iOS 6 armv7 (retro, sideload) | **wasm2c** (packaging) | host in Objective-C / C, or Embedded Swift built with Swift-iOS6's toolchain setup (Swift 6.4 Embedded, `armv7-apple-none-macho`); an interpreter (WasmKit as Embedded Swift, or wasm3) is for development only, since it's too slow on Cortex-A8-class hardware |
| Linux distro | WasmKit, then install-time AOT | no JIT ban on Linux, so modules can be compiled to native code at install time and cached |

No JIT on iOS: AOT engines that map executable memory at runtime (for example WAMR AOT) can't be used there.

Development mode: interpreter with hot reload. Release mode: wasm2c output compiled into the app.

---

## 12. Build pipeline

```
Contracts (.swift) ──► macro ──► guest proxies + custom sections
        │
        └──► build plugin ──► Java interfaces / ObjC headers / C headers / host adapters

App sources ──► swiftc (Embedded, wasm32) ──► App.wasm
App.swift manifest ─┐
App.wasm sections ──┴► packager ──► validate ──► per-platform outputs
        iOS/macOS: Info.plist, InfoPlist.strings, .entitlements, (wasm2c) → .app
        Android:   AndroidManifest.xml, res/, Java stubs → .apk/.aab
        Linux:     Info.plist, .lproj → .app bundle
```

---

## 13. Why wasm32 and not wasm64

- Memory64 is standardized in Wasm 3.0, and WasmKit implements it.
- The Swift toolchain only targets wasm32.
- Native objects live in the host; the guest holds 32-bit handles. A UIKit-scale app's guest heap stays far below 4 GB.
- wasm64 would make guest `Int` match `NSInteger` on arm64 but not on armv7, so the wire format is needed either way.
- wasm64 costs larger pointers and loses guard-page bounds-check elimination.

---

## 14. App Store considerations

- `objc_msgSend` and the rest of the ObjC runtime API are **public**. Using them is not private API use.
- Calling **private selectors** through the runtime is still private API use.
- Guideline 2.5.2 forbids downloading or executing code that adds or changes app functionality. DPLA 3.3.1(B) allows downloaded interpreted code only within narrow limits. A generic native bridge driven by downloaded code is the pattern Apple rejected in 2017 (JSPatch, Rollout).
- Therefore:
  - The `.wasm` ships **inside the bundle**. No OTA code updates in App Store builds.
  - The host enforces an **allowlist** generated from the custom sections and manifest. Only contracts and selectors the module declares can be resolved.
  - Release builds may use wasm2c, so no interpreter ships at all.

---

## 15. Open questions

- When upstream Embedded Observation ships, retire the stopgap module; until then, track API changes in the pitch.
- Whether one libc-agnostic ELF slice per architecture can serve both Linux and Android (`elf-arm64` instead of `linux-arm64` + `android-arm64-v8a`); verify by linking the same `libapp.a` against musl/glibc and bionic.
- Binary encoding for the render IR (custom, or a schema-driven format usable from Kotlin, Swift and JS).

- Should the native-binding mode (raw UIKit / android.jar) share the `rt_class` namespace with contracts, or get its own import, to avoid ambiguity?
- Error model: carry structured errors (domain + code) in addition to the message string?
- Contract evolution tooling: diff contract versions in CI to block breaking changes.
- Debugging: DWARF in wasm with WasmKit's debugger support, versus wasm2c builds debugged as native code.
- Multiple guest instances (extensions, widgets): one module per process, or shared?

---

## 16. Roadmap

1. `rt.h` runtime core with the Swift-registry backend, linked two ways: natively and behind a WasmKit import shim (Linux/macOS). Same test app in both modes.
2. `@DynamicRuntime` / `@DynamicCallback` macros + guest proxy generation.
3. `Central` / `Peripheral` Bluetooth contracts end to end on Linux (BluetoothLinux).
4. ObjC backend (libffi, `_objc_msgForward` callbacks) + iOS host app.
5. JNI backend + Java interface generator + Android host.
6. Manifest packager: Info.plist / AndroidManifest / Linux bundle, with capability validation.
7. wasm2c release pipeline.
8. GLES 2.0 imports (WebGL 1 rules), `GLSurface` IR node, ANGLE-on-Metal backend for modern Apple hosts.
9. Stopgap Embedded `Observation` module matching the upstream pitch API.
10. SwiftUI frontend (from Swift-iOS6) emitting the `RenderNode` IR; Compose (AndroidSwiftUI), UIKit (Swift-iOS6 backend) and SwiftUI players.
11. Platform layers: subclassing, generated SDK bindings.
12. iOS 6 host (Objective-C / C or Embedded Swift) with wasm2c-packaged guests.

---

## References

- WasmKit: <https://github.com/swiftwasm/WasmKit>
- WebAssembly 3.0 (memory64, exception handling, GC)
- Apple App Review Guidelines §2.5.2; Apple Developer Program License Agreement §3.3.1(B)
- NativeScript runtime architecture (metadata-driven ObjC/JNI access, static binding generator)
- swift-java / JavaKit (`@JavaClass` / `@JavaMethod` macro model)
- PureSwift/AppRuntime: <https://github.com/PureSwift/AppRuntime> (multi-arch bundle format, arch selection, Linux sandbox launcher; superseded, parts carried over)
- PureSwift/AndroidSwiftUI: <https://github.com/PureSwift/AndroidSwiftUI> (`RenderNode` IR, Compose interpreter)
- colemancda/Swift-iOS6: <https://github.com/colemancda/Swift-iOS6> (Embedded Swift on iOS 6, ObjCInterop macros, Embedded SwiftUI with UIKit backend)
- Swift Forums pitch, "Observation performance and modeling improvements" (Oct 2026): <https://forums.swift.org/t/pitch-observation-performance-and-modeling-improvements/89924>
- ElementaryUI: <https://github.com/elementary-swift/elementary-ui> (Embedded Swift UI framework for the browser)

---

## Appendix A — `rt.h`

```c
/*
 * rt.h — portable dynamic-runtime ABI between a wasm32 guest and a native host.
 *
 * The intersection of the Objective-C runtime, JNI, and a plain C host (SDL3).
 * Anything not present in all three is excluded from the core.
 *
 * Backends:
 *   ObjC  — objc_getClass / sel_registerName / objc_msgSend(_stret) via libffi
 *   JNI   — FindClass / Get(Static)MethodID / Call<T>MethodA / NewObjectA
 *   C     — host-side registry of functions and handle-wrapped pointers
 */
#ifndef RT_H
#define RT_H

#include <stdint.h>
#include <stddef.h>

/*
 * One header, two linkages. App source is identical in both.
 *
 *   wasm32:  rt_* are imports from module "rt", provided by the host's wasm
 *            shim, which converts guest offsets to native pointers and calls
 *            the same runtime core. rt_dispatch / rt_finalize are exports.
 *
 *   native:  rt_* are ordinary C symbols exported by the runtime library
 *            (static lib, RT.framework, librt.so). rt_dispatch / rt_finalize
 *            are ordinary symbols defined by the app and called by the runtime.
 *
 * Handles, wire slots and every rule below are the same in both modes.
 * Neither form is an executable: a wasm slice is a WASI reactor module, a
 * native slice is a sealed static library. The host links or loads it.
 */
#if defined(__wasm__)
#  define RT_IMPORT(name) __attribute__((import_module("rt"), import_name(#name)))
#  define RT_EXPORT(name) __attribute__((export_name(#name)))
#else
#  define RT_IMPORT(name) extern __attribute__((visibility("default")))
#  define RT_EXPORT(name) __attribute__((visibility("default")))
#endif

/* ------------------------------------------------------------------------- */
/* Values                                                                     */
/* ------------------------------------------------------------------------- */

/* Opaque, refcounted reference to a host object. 0 is null.
 * Handles are NOT guaranteed unique per object (JNI has no stable identity
 * key); compare objects with rt_same(). */
typedef uint32_t rt_obj;

/* Resolved class / method identifiers. Never released. 0 is invalid. */
typedef uint32_t rt_class_id;
typedef uint32_t rt_method_id;

/* One wire slot per scalar. f32 is stored as its bit pattern in the low 32
 * bits, bool as 0/1, rt_obj in the low 32 bits. */
typedef uint64_t rt_slot;

/*
 * Wire signature grammar (portable, used only for marshaling):
 *
 *   sig    := '(' arg* ')' ret
 *   arg    := 'Z' | 'I' | 'J' | 'F' | 'D' | 'O'
 *   ret    := arg | 'V'
 *
 *   Z bool   I int32   J int64   F float32   D float64   O object (nullable)
 *
 * No unsigned, no 8/16-bit, no pointers, no structs, no varargs.
 * The host narrows/widens to the native type (e.g. I -> BOOL/char/short,
 * J -> NSInteger on armv7, D -> CGFloat on armv7) using the native signature
 * it reads at runtime (method_getTypeEncoding, JNI descriptor, C table).
 *
 * Native structs (CGRect, CGSize, ...) are flattened: one slot per scalar
 * field, in declaration order. Backends without structs never see them.
 */

/* Status codes returned by every fallible call. */
typedef enum {
    RT_OK            = 0,
    RT_ERR_NOT_FOUND = 1,   /* class or method missing on this platform/OS */
    RT_ERR_SIGNATURE = 2,   /* wire sig does not fit the native signature */
    RT_ERR_THROWN    = 3,   /* NSException / Throwable / C error; see rt_error */
    RT_ERR_NULL      = 4,   /* message to null where the backend forbids it */
} rt_status;

/* Method lookup flags. */
enum {
    RT_METHOD_INSTANCE = 0,
    RT_METHOD_STATIC   = 1,  /* ObjC class method, Java static, C function */
    RT_METHOD_CTOR     = 2,  /* ObjC alloc+init…, Java <init>, C constructor */
};

/* ------------------------------------------------------------------------- */
/* Imports (host -> guest)                                                    */
/* ------------------------------------------------------------------------- */

/* Look up a class. Two kinds of name, resolved in this order:
 *
 *   1. Contract name (portable, reverse-DNS), e.g.
 *        "org.pureswift.bluetooth.Central"
 *      Declared once in Swift; the host's registry maps it to whichever
 *      implementation this platform provides (Java class, ObjC class,
 *      Swift type, or C function table).
 *
 *   2. Native name (platform bindings only), e.g.
 *        ObjC "UIView"   JNI "android/view/View"   C "SDL_Window" */
RT_IMPORT(class)
rt_class_id rt_class(const char *name, size_t len);

/* Look up a method.
 *   Contract classes: `name` is the portable selector-style key derived from
 *     the Swift declaration ("connect:timeout:"). Contracts forbid overloads,
 *     so name + arity is unique; each backend maps it (Java method "connect",
 *     ObjC "-connect:timeout:error:", Swift registry entry).
 *   Native classes: `name` is the native key, opaque to the core:
 *     ObjC "setTitle:forState:"
 *     JNI  "setText(Ljava/lang/CharSequence;)V"
 *     C    "SDL_CreateWindow"
 * `sig` is the portable wire signature used for marshaling. */
RT_IMPORT(method)
rt_method_id rt_method(rt_class_id cls,
                       const char *name, size_t name_len,
                       const char *sig,  size_t sig_len,
                       uint32_t flags);

/* Invoke a method.
 *   INSTANCE: target = receiver
 *   STATIC:   target ignored (pass 0)
 *   CTOR:     target ignored; ret[0] receives a new +1 rt_obj
 * Returned objects are always +1; the guest must rt_release them. */
RT_IMPORT(call)
rt_status rt_call(rt_obj target, rt_method_id method,
                  const rt_slot *args, uint32_t nargs,
                  rt_slot *ret, uint32_t nret);

/* Reference counting. Backed by retain/release (ObjC), global refs (JNI),
 * or a host refcount + destroy function (C). */
RT_IMPORT(retain)  void rt_retain(rt_obj obj);
RT_IMPORT(release) void rt_release(rt_obj obj);

/* Identity and type tests. */
RT_IMPORT(same)        int32_t rt_same(rt_obj a, rt_obj b);
RT_IMPORT(is_instance) int32_t rt_is_instance(rt_obj obj, rt_class_id cls);

/* Strings: NSString / java.lang.String / host UTF-8 buffer. +1 result.
 * rt_string_utf8 returns the full UTF-8 length; copies at most `cap` bytes. */
RT_IMPORT(string_new)  rt_obj rt_string_new(const char *utf8, size_t len);
RT_IMPORT(string_utf8) size_t rt_string_utf8(rt_obj str, char *buf, size_t cap);

/* Bytes: NSData / byte[] / host buffer. Same copy semantics as strings.
 * The host never retains pointers into guest memory. */
RT_IMPORT(bytes_new)  rt_obj rt_bytes_new(const void *ptr, size_t len);
RT_IMPORT(bytes_read) size_t rt_bytes_read(rt_obj bytes, void *buf, size_t cap);

/* Callbacks: implement one or more interfaces/protocols with guest functions.
 *   ObjC: runtime class conforming to the protocols, IMPs forward to rt_dispatch
 *   JNI:  java.lang.reflect.Proxy over the interfaces
 *   C:    host callback set (function pointer + userdata)
 * Subclassing concrete classes is NOT in the core (JNI cannot do it at runtime).
 * `context` is passed back to rt_dispatch and rt_finalize. Returns +1. */
typedef struct {
    const char *name;  size_t name_len;  /* native lookup key, as in rt_method */
    const char *sig;   size_t sig_len;   /* wire signature */
} rt_method_decl;

RT_IMPORT(implement)
rt_obj rt_implement(const rt_class_id *interfaces, uint32_t ninterfaces,
                    const rt_method_decl *methods, uint32_t nmethods,
                    uint32_t context);

/* Last error on this thread after RT_ERR_THROWN; clears it.
 * Returns full UTF-8 length of the message; copies at most `cap` bytes. */
RT_IMPORT(error_message)
size_t rt_error_message(char *buf, size_t cap);

/* ------------------------------------------------------------------------- */
/* Exports (guest -> host)                                                    */
/* ------------------------------------------------------------------------- */

/* Entry point. The host owns main() and the run loop; it calls rt_main once
 * after loading the app (after _initialize for a wasm reactor module). The app
 * sets itself up (creates contracts, a renderer, delegates) and returns.
 * Everything afterward arrives through rt_dispatch. */
RT_EXPORT(rt_main)
rt_status rt_main(void);

/* Called when a native caller invokes a method created by rt_implement.
 * `index` is the position in the rt_method_decl array. Argument objects are
 * borrowed (+0); returned objects must be +1. */
RT_EXPORT(rt_dispatch)
rt_status rt_dispatch(uint32_t context, uint32_t index, rt_obj self,
                      const rt_slot *args, uint32_t nargs,
                      rt_slot *ret, uint32_t nret);

/* Called once when the native object created by rt_implement is destroyed
 * (dealloc / Proxy collected / host destroy). Free guest state for `context`. */
RT_EXPORT(rt_finalize)
void rt_finalize(uint32_t context);

/* ------------------------------------------------------------------------- */
/* Rules                                                                      */
/* ------------------------------------------------------------------------- */
/*
 * - Single-threaded: all calls in both directions happen on the UI/main thread.
 *   The host moves callbacks there before entering the guest.
 * - The host never stores pointers into guest linear memory past the call.
 * - Excluded from the core (not in all three runtimes): fields/ivars, weak refs,
 *   structs as values, unsigned/narrow ints, varargs, runtime subclassing of
 *   concrete classes, collections beyond bytes, autorelease pools (host-internal).
 *   Platform binding layers may add backend-specific imports on top.
 */

#endif /* RT_H */
```
