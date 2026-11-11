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

Not in phase one: platform hosts and backends (ObjC, JNI), renderers, the
manifest packager (`App.swift` → Info.plist / AndroidManifest), wasm2c, GLES,
the Observation stopgap, the guest executor and async wrappers, the SwiftUI
frontend. TCP and UDP are not part of the spec.

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

1. **wasm allocator exports.** `rt.h` is verbatim. A wasm host has to place
   `rt_dispatch` arguments and results in linear memory, which the ABI has
   no way to do, so the guest also exports `rt_alloc` / `rt_free`
   (`rt_guest.h`, defined in `rt.c`). Every wasm host, including a browser
   host, needs them or an equivalent.
2. **Error messages from guests.** A guest-implemented method that throws
   returns `RT_ERR_THROWN`, but `rt.h` gives a guest no way to pass a
   message. In native mode the message crosses in-process
   (`Exported.takeDispatchErrorMessage()`); from a wasm guest it is lost.
   This belongs with the error-model open question (§15).
3. **`rt_error_message` with `cap == 0`** reports the length without
   clearing the message, so a caller can size its buffer and read it.
   Any read with `cap > 0` clears it.

**Implementation choices:**

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
| `linux-arm64`, `android-arm64-v8a` | `aarch64-none-none-elf` | |
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
5. **x86_64** uses the x86-64-v2 baseline (SSE4.2, POPCNT; Android x86_64
   requires it), so `ceil` compiles to an instruction instead of a libm call.
6. **`arc4random_buf`.** The Embedded stdlib calls it to seed hashing.
   It is in the allowed set as "random", but **musl doesn't provide it**.
   On a musl distro, `librt.so` (or a shim at install-time link) has to
   supply it.
7. **No concurrency in native slices yet.** Native slices are compiled with
   `EMBEDDED_NO_CONCURRENCY`, because the prebuilt concurrency runtime needs
   the guest executor's hooks (§5.4), which don't exist yet, and more libc than
   §7.5 allows. Separately, the toolchain ships no `_Concurrency` module at
   all for `aarch64-none-none-elf`, so `linux-arm64` and `android-arm64-v8a`
   will still need a runtime built for them. `canImport(_Concurrency)`
   returns true on that triple, because the module exists for others, so
   packages check the define. wasm32 links the runtime.
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
  re-entrancy, `List`, errors, validation.
- `DynamicRuntimeTests`: the example app as a native slice, end to end
  (every wire type, callbacks both ways, throws, lists, identity, capability
  gating, leak check).
- `RuntimeWasmTests`: the import shim with hand-written WAT guests, and the
  same example app as `App.wasm` (built by `Scripts/build-wasm.sh
  ExampleApp`; skipped without it), including `rt.contracts` validation.
- `ContractsTests`: names, capabilities, keys and signatures of the provider
  contracts.

## 6. Next

1. Settle the review items in §3 (allocator exports, guest error messages).
2. Guest-side executor and `Clock` contract (§5.4); async wrappers over the
   provider contracts.
3. Stopgap `Observation` module (§5.3) and the Embedded SwiftUI frontend
   emitting the render IR (§9), both guest code for this repository.
4. Manifest packager: `App.swift` → Info.plist / AndroidManifest, signing.
5. Hosts and backends (ObjC, JNI, Linux `rt-host`), in their own
   repositories or later here (Linux only).
