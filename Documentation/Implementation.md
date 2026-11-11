# DynamicRuntime — Phase One Implementation

Status of the shared code against [the design](DynamicRuntime.md): what
exists, how it fits together, where it departs from the design, and what the
toolchain allows today.

Toolchain: Swift 6.4.2 (`.swift-version`) with the matching Embedded wasm
Swift SDK.

## 1. Scope

Phase one covers roadmap items 1 and 2 (§16) for the shared code, plus guest
builds and the first provider contracts:

| Roadmap item | Status |
|---|---|
| `rt.h` runtime core with the Swift-registry backend, linked natively and behind a WasmKit import shim; same test app in both modes | done: `RuntimeCore`, `RuntimeNative`, `RuntimeWasm`; the example app passes in both modes |
| `@DynamicRuntime` / `@DynamicCallback` macros and guest proxy generation | done: `DynamicRuntimeMacros`, `DynamicRuntime` |
| Guest builds: sealed native slices, `App.wasm` reactor, universal bundle (§7.5) | done: `Scripts/guest.py` and wrappers |
| Provider contracts: Bluetooth, Location, URL/HTTP, number and date formatting | declared: `DynamicBluetooth`, `DynamicLocation`, `DynamicNetworking`, `DynamicFormatting`; no host implementations |
| Guest executor and `Clock` contract (§5.4, §7.4) | done: `GuestExecutor`, `RuntimeClock`, `HostClock`; runs in `App.wasm` and every native slice (arm64 ELF needs `Scripts/fetch-embedded-linux.sh`) |
| Async wrappers over the provider contracts (§6.2.1) | done: `EventStream`, `withCallback`, and an `Async…` wrapper per contract; tested against fake hosts |

Not in phase one: platform hosts and backends (ObjC, JNI), renderers, the
manifest packager (`App.swift` → Info.plist / AndroidManifest), wasm2c, GLES,
the Observation stopgap, the SwiftUI frontend. TCP and UDP are not part of the spec.

## 2. Layout

```
            guest (Embedded Swift)                     host
 ┌───────────────────────────────────────┐   ┌──────────────────────────────┐
 │ app            ExampleApp, rt_main     │   │ Swift implementations        │
 │ contracts      Dynamic*, @macros       │   │ (ExampleHost) use the same   │
 │ DynamicRuntime proxies, rt_dispatch    │   │ proxies, via RuntimeNative   │
 │ RuntimeABI     wire model              │   │                              │
 │ CRuntime       rt.h                    │   │ RuntimeWasm   WasmKit shim   │
 └──────────────┬────────────────────────┘   │ RuntimeNative rt_* symbols   │
                │ rt_* (wasm imports or C)    │ RuntimeCore   handle table,  │
                └────────────────────────────▶│               registry       │
                                              └──────────────────────────────┘
```

- `RuntimeCore.HostRuntime` is instance-based. `RuntimeNative` exports the
  `rt_*` C symbols over `NativeRuntime.shared`; `RuntimeWasm` binds a wasm
  instance's `rt` imports to any `HostRuntime`, normally the same shared one,
  so host objects and wasm objects live in one handle table.
- Each object made by `rt_implement` remembers its `Guest`: the wasm instance
  (`WasmGuest`, called through its exports) or native code in the process
  (`NativeGuest`, called through the `rt_dispatch` C symbol).
- **Host Swift code is a native guest.** A Swift implementation of a contract
  is registered as a class with a static-method table. Its instances are
  exported with `rt_implement` through the native `rt_*` symbols, and it
  receives object arguments as proxies. The Swift-registry backend is
  therefore the same proxy and dispatch code the guest uses, and a host
  object can be recovered with `NativeRuntime.swiftObject(for:)`.

## 3. Decisions and departures from the design

**Need your review:**

1. **Error messages from guests.** A guest-implemented method that throws
   returns `RT_ERR_THROWN`, but `rt.h` gives a guest no way to pass a
   message. In native mode the message crosses in-process
   (`Exported.takeDispatchErrorMessage()`); from a wasm guest it is lost.
   This belongs with the error-model open question (§15).
2. **`rt_error_message` with `cap == 0`** reports the length without
   clearing the message, so a caller can size its buffer and read it.
   Any read with `cap > 0` clears it.

**Implementation choices:**

- **Async wrappers** (§6.2.1) are hand-written, one per contract, in the
  contract modules, under `!EMBEDDED_NO_CONCURRENCY`. Embedded Swift has no
  `any Error` values, so streams are `EventStream<Element, Failure>` (a
  typed-failure `AsyncSequence`) instead of `AsyncThrowingStream`, and
  one-shot calls use `withCallback`, a typed-throws continuation. Its
  continuation and the request lists (`PendingCallbacks`, `EventSubscribers`)
  are classes. As structs kept in a delegate's properties, finishing a stream
  would hold an access to the property while its `onTermination` cleared it,
  which is an exclusivity violation. A stream's consumer side releases it,
  so dropping a stream stops the native work. `LocationError`, `MotionError`
  and `NFCError` gained a guest-side `cancelled` code (hosts never send it),
  like `BluetoothError.operationCancelled` and `NetworkError.cancelled`.
- **Executor hooks are C** (`CRuntime/executor.c`, compiled only under
  `__EMBEDDED_SWIFT__` without `EMBEDDED_NO_CONCURRENCY`). As Swift
  `@_silgen_name` functions they were serialized into `DynamicRuntime`'s
  module, and every module importing it failed to build without
  optimization ("linkage mismatch of function
  'swift_task_enqueueGlobalWithDelayImpl'"), which broke
  `swift build --swift-sdk …wasm-embedded` for the contract modules.
  `guest.py` builds weren't affected. `guest.py` now passes its defines to
  clang too.
- **wasm allocator.** `rt.h` declares two more wasm32 exports, `rt_alloc`
  and `rt_free` (defined in `rt.c` over `malloc`). A wasm host has to place
  `rt_dispatch` arguments and results in linear memory, which the ABI had no
  other way to do, so every wasm host, including a browser host, uses them.
  Native hosts pass their own pointers and never call them.
- **Contracts are class-bound** (`protocol Central: AnyObject`). Embedded
  Swift only supports existentials of class-bound protocols, and contract
  parameters such as `Peripheral` are existentials. The macro reports a
  missing `AnyObject` with a fix-it. The design's examples omit it.
- **Raw string types.** A contract can declare a `RawRepresentable` type with
  `String` raw values, such as `BluetoothUUID`; it travels as its `rawValue`.
  A macro only sees syntax, so generated code calls `_rtEncode` and
  `_rtDecode…` by name and the compiler picks between each contract's overloads
  and the generic ones in `DynamicRuntime`. A method returning such a type must
  be declared `throws` (anything else is a compile error), and an invalid
  string throws `RuntimeError.thrown`. An invalid callback argument fails the
  incoming call the same way.
- **Method keys:** the base name, `:` for the first parameter, then
  `label:` per later parameter (`connect(_:timeout:)` → `connect:timeout:`,
  `replaceSubtree(_:_:)` → `replaceSubtree::`). See `RuntimeABI.MethodKey`.
- **Method kinds:** a static method returning `Self` or `Self?` is a
  constructor (`Self?` can fail, with a null result); any other static
  method is `RT_METHOD_STATIC`.
- **Dispatch indices** count instance methods and static methods
  separately, in declaration order.
- **Identity:** exporting the same Swift object as the same interface again
  reuses its context, and `rt_same` treats two objects with the same guest
  and context as one object. Handles stay non-unique, as in the design.
- **Throws:** contract methods may use `throws` or `throws(RuntimeError)`.
  Proxies throw `RuntimeError`; a failed call from a non-throwing method
  traps.
- **Metadata (§10).** The macro emits each contract's record with
  `@used @export(interface) @section(...)` into `__DATA,__rt_contracts`
  (Mach-O) or `.rt_contracts` (ELF), chosen by `objectFormat(...)`.
  `@export(interface)` stops Embedded Swift from emitting the record again
  in every importing module. Swift can't emit wasm custom sections, so
  `guest.py` copies the records from an ELF build into `App.wasm`'s
  `rt.contracts` custom section. `rt.abi` comes from `rt.c`, through
  module-level assembly on wasm.
- **`List`** is built into `RuntimeCore`; its descriptor lives in
  `RuntimeABI.BuiltinContracts`.
- **Embedded constraints met:** no key paths, no existentials of non-class
  protocols, no generic code on `AnyObject` values (identity uses `===`),
  and `String` comparison links `libswiftUnicodeDataTables`.

## 4. Guest builds

`Scripts/guest.py` reads the package graph (`swift package describe`),
builds macro plugins for the build machine, compiles every C and Swift
target of the guest product with `swiftc` / `clang`, seals each native slice
and links `App.wasm`. Wrappers: `Scripts/build-{wasm,ios,macos,tvos,watchos,visionos,linux,android}.sh`
and `Scripts/build-bundle.sh`.

| Target ID | Triple | Notes |
|---|---|---|
| `wasm32` | `wasm32-unknown-wasip1` | WASI reactor (`-mexec-model=reactor`), debug info stripped, `rt.contracts` added |
| `ios-armv7` | `armv7-apple-none-macho`, stamped iOS 6.0 | Swift-iOS6 setup: `-marm -ffixed-r9`, soft-float helpers from libSystem, `memset_s` / `__cxa_pure_virtual` sealed in |
| `ios-arm64` | `arm64-apple-none-macho`, stamped iOS 13.0 | |
| `macos` | arm64 none-macho (11.0) + `x86_64-apple-macos14` stamped 10.15 | fat archive |
| `tvos-arm64`, `visionos-arm64` | `arm64-apple-none-macho`, stamped tvOS 13 / visionOS 1 | |
| `watchos-arm64` | `arm64-apple-none-macho`, stamped watchOS 6 | arm64 watches only |
| `linux-arm64`, `android-arm64-v8a` | `aarch64-none-none-elf`; `aarch64-unknown-linux-gnu` for concurrency | see finding 7 |
| `linux-armv7` | `armv7-none-none-eabi`, `-mfloat-abi=hard` | armhf |
| `android-armeabi-v7a` | `armv7-none-none-eabi`, `-mfloat-abi=softfp` | |
| `linux-x86_64`, `android-x86_64` | `x86_64-unknown-none-elf`, CPU `nehalem` (x86-64-v2) | |

Every native slice is one `ld -r` object in `libapp.a`. Only `rt_main`,
`rt_dispatch` and `rt_finalize` stay global, and the build fails if:
- any undefined symbol falls outside the §7.5 set;
- the slice has glibc-only references;
- an export or the `rt.abi` section is missing.

`App.wasm` is checked for `rt` / WASI-only imports and the reactor exports.
The bundle step:
- validates contract capabilities against `--capability` (§7.3);
- writes `Info.plist` (`RTTargets`, `RTABIVersion`, `RTCapabilities`,
  `RTContracts`);
- writes per-file SHA-256 hashes to `_CodeSignature/CodeResources` (unsigned).

### Findings

Each of these needs a decision, or is verified only as far as noted:

1. **Apple deployment floors.** The toolchain's Embedded stdlib for OS
   triples requires iOS 18 / macOS 14, and it has none for tvOS, watchOS or
   visionOS. Embedded code makes no OS calls, so the slices are built for
   `none-macho` (same Darwin calling convention) and stamped with the
   platform at seal time. They link, but haven't run on devices.
2. **watchOS 6 hardware is arm64_32,** for which no Embedded stdlib
   exists. `watchos-arm64` covers arm64 watches only; arm64_32 watches need
   `App.wasm` (wasm2c in the host's packager).
3. **armv7 Linux and Android are different slices.** Linux armhf passes
   floats in VFP registers; Android armeabi-v7a passes them in core
   registers. Checked by disassembly.
4. **armv7 ELF runtime support.** The toolchain has no bare-metal
   compiler-rt for ARM. The slice seals private copies of the integer
   division and 64-bit shift helpers, inert unwind personality stubs, and
   `ceil` (`Scripts/support/armv7-eabi.c`, localized when sealing). The
   `__aeabi_mem*` names are allowed as the EABI spelling of
   memcpy/memset, which glibc, musl and bionic export. The helpers match
   libc results in a host test. They haven't run on armv7 hardware.
   Every ELF slice also seals `sqrt` and `sqrtf` (`Scripts/support/math.c`):
   Swift's `squareRoot()` calls `sqrt`, which isn't in the §7.5 set. Each
   compiles to the architecture's square root instruction. Apple slices get
   libm from libSystem.
5. **x86_64** uses the x86-64-v2 baseline (SSE4.2, POPCNT; Android x86_64
   requires it), so `ceil` compiles to an instruction instead of a libm call.
6. **`arc4random_buf`.** The Embedded stdlib calls it to seed hashing.
   It is in the allowed set as "random", but **musl doesn't provide it**.
   On a musl distro, `librt.so` (or a shim at install-time link) has to
   supply it.
7. **Concurrency.** Every slice links the Embedded concurrency runtime, and
   `GuestExecutor` supplies its executor hooks (§5.4). Native slices also seal
   in `Scripts/support/concurrency.c`: the runtime calls a little libc outside
   §7.5 on paths a guest never takes (fatal-error printing, the replaced
   cooperative executor's sleep), and references Swift functions that only a
   dead-stripping link removes, which a relocatable seal can't do on Mach-O.
   The runtime libraries are linked without their debug info (2.6 MB of DWARF
   in the ELF one). The runtime adds about 125 KB to an arm64 Mach-O slice
   and 200 KB to an ELF one. Apple slices may reference the stack protector,
   which libSystem provides.

   **arm64 ELF.** The toolchain has no `_Concurrency` module or runtime for
   `aarch64-none-none-elf`, and won't load the `aarch64-unknown-linux-gnu`
   module under it ("created for incompatible target", even with
   `-disable-target-os-checking`). So `linux-arm64` and `android-arm64-v8a`
   are compiled for `aarch64-unknown-linux-gnu` when that triple's Embedded
   modules and runtime are available: in an arm64 Linux toolchain, or copied
   from the `swift` Docker image by `Scripts/fetch-embedded-linux.sh` (28 MB,
   into `~/.cache/appruntime/swift-<version>/embedded`, or `RT_EMBEDDED_DIR`).
   The code is the same AAPCS64 code, compiled freestanding, with no TLS, but
   **`os(Linux)` is true** in these two slices and nowhere else. That runtime
   was built for a hosted Linux, so `Scripts/support/aarch64-linux.c` seals
   in what libgcc, libstdc++ and glibc would provide:
   - outline atomics;
   - the red-black tree that task groups and task locals use. It was written
     from the textbook algorithm and tested against libstdc++'s `std::set` in
     the `swift` image.
   - `__errno_location` and `stderr`;
   - a private stack protector canary.

   A probe guest's sealed `linux-arm64` slice ran in the `swift:6.4.2` arm64
   image (glibc) under a minimal C host. It ran a task group, a sleep resumed
   by the host's timer, and finished with no live handles. musl and bionic
   haven't been run. Without the copy, these slices are built with
   `EMBEDDED_NO_CONCURRENCY`, and `guest.py` says so. `canImport(_Concurrency)`
   returns true on `aarch64-none-none-elf`, because the module exists for
   other triples, so packages check the define.
8. **iOS 6** still needs the host's stack realignment on calls into the
   slice, and the Thumb-bit fixup for the prebuilt concurrency runtime after
   the final link (Swift-iOS6's `objcrt_call_aligned` and `thumbfix.py`).
   Both are host jobs.
9. **Package settings** (defines, unsafe flags, conditional dependencies)
   aren't read by `guest.py`; every target is compiled as an Embedded Swift
   library with fixed flags.

## 5. Tests

- `RuntimeABITests`: signatures, slots, keys, metadata encoding.
- `DynamicRuntimeMacrosTests`: model, expansion shape and contract-rule
  diagnostics.
- `RuntimeCoreTests`: registry, calls, `rt_implement`, finalization and
  re-entrancy, `List`, `Clock` and `ManualClock`, errors, validation.
- `DynamicRuntimeTests`: the example app as a native slice, end to end
  (every wire type, callbacks both ways, throws, lists, identity, capability
  gating, leak check).
- `RuntimeWasmTests`: the import shim with hand-written WAT guests, and the
  same example app as `App.wasm` (built by `Scripts/build-wasm.sh
  ExampleApp`; skipped without it), including `rt.contracts` validation and
  its async checks: tasks run before `rt_main` returns, sleeps resume when
  the test advances a `ManualClock`, and cancellation before and during a
  sleep. Embedded only: in host tests Swift's own executor runs guest code.
- Contract test targets (`DynamicBluetoothTests`, `DynamicLocationTests`,
  …): names, capabilities, keys and signatures of the provider contracts, and
  their async wrappers against fake Swift hosts through `NativeRuntime`:
  permissions, one-shot calls, streams starting and stopping, failures,
  cancellation, and handle and export leak checks.
- `DynamicRuntimeTests/AsyncHelperTests`: `EventStream` buffering,
  failure, and termination on finish, cancellation and release;
  `withCallback`; `PendingCallbacks` ordering; `EventSubscribers` fan-out.

## 6. Next

1. Settle the review items in §3 (allocator exports, guest error messages).
2. Stopgap `Observation` module (§5.3) and the Embedded SwiftUI frontend
   emitting the render IR (§9), both guest code for this repository.
3. Manifest packager: `App.swift` → Info.plist / AndroidManifest, signing.
4. Hosts and backends (ObjC, JNI, Linux `rt-host`), in their own
   repositories or later here (Linux only).
