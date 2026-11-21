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
| `rt.h` runtime core with the Swift-registry backend, linked natively and behind a WasmKit import shim; same test app in both modes | done: `RuntimeCore`, `RuntimeNative`, `RuntimeWasm` (`Packages/RuntimeWasm`); the example app passes in both modes |
| `@DynamicRuntime` / `@DynamicCallback` macros and guest proxy generation | done: `DynamicRuntimeMacros`, `DynamicRuntime` |
| Guest builds: sealed native slices, `App.wasm` reactor, universal bundle (§7.5) | done: `Scripts/guest.py` and wrappers. A Linux slice is `libapp.so`, which a runner loads as it is (§7.6) |
| Provider contracts: Bluetooth, Location | declared: `DynamicBluetooth`, `DynamicLocation`; the platform hosts implement them |
| URL and HTTP | declared: `DynamicNetworking`; `RuntimeNetworking` implements it over Swift Foundation's `URLSession` for any host written in Swift, on Apple platforms and on Linux, where `URLSession` is `FoundationNetworking` over libcurl. The Darwin host has its own `DarwinNetworking`, which it's a port of; the Linux host doesn't register it yet. Callbacks arrive on a queue of each session's own and reach the guest on the main thread through `HostNetworkingModule.deliver`, which a host with a loop of its own points at that loop; what the contracts couldn't do as asked goes to `HostNetworkingModule.log` |
| Number and date formatting | declared: `DynamicFormatting`; `RuntimeFormatting` implements `LocaleInfo`, `NumberFormat` and `DateFormat` over Swift Foundation for any host written in Swift, on Apple platforms and Linux. The Linux and Darwin hosts register it. What a guest asks for that the contracts don't know, such as an unknown style or time zone, is replaced and told to `HostFormattingModule.log`, which the host points at its logger |
| Guest executor and `Clock` contract (§5.4, §7.4) | done: `GuestExecutor`, `RuntimeClock`, `HostClock`; runs in `App.wasm` and every native slice (arm64 ELF needs `Scripts/fetch-embedded-linux.sh`) |
| `Permissions`, `Bundle` and `Application` built-ins (§7.4) | declared: `Permissions`, `AppBundle`, `Application` in `DynamicRuntime`; tested against fake hosts |
| Async wrappers over the provider contracts (§6.2.1) | done: `EventStream`, `withCallback`, and an `Async…` wrapper per contract; tested against fake hosts |
| Observation stopgap (§5.3) | done: `DynamicObservation`, `ObservationMacros` (`Observation` in guest builds) |
| SwiftUI frontend, render IR and renderer contract (§9) | done: `DynamicSwiftUI` (`SwiftUI` in guest builds), `DynamicUI`, `Documentation/RenderIR.md`; no players |
| wasm2c import shim (§11) | done: `Scripts/wasm2c-shim.py` (WABT's wasm2c); `ExampleApp` and `ExampleUI` pass through it |
| Files (§7.9) | done: `DynamicFiles` (the `Files` contract and the guest's `FileManager`), and `HostFiles` in `RuntimeHost`, the contract over POSIX calls for the Darwin and Linux hosts; `examples/ExampleFiles`. The Darwin host registers it on iOS and macOS (DarwinAppRuntime's `DarwinFiles`). Android and the browser need their own host side |
| Documents (`Contracts/Documents.md`) | done on the guest side, with the shared host side: `DynamicDocuments` (the `Documents` and `DocumentGrant` contracts, the guest's `DocumentPicker`, `Document` and `ContentType`, and the `fileImporter` and `fileExporter` modifiers), grant directories in `HostFiles`, and `RuntimeDocuments` (`HostDocuments`, the contracts over a host's `DocumentPresenter`); the `.userFiles` capability and `documentTypes` in the manifest; `examples/ExampleDocuments`. The Darwin host shows the pickers on iOS and macOS (DarwinAppRuntime's `DarwinDocuments`); no other host does yet |
| Media players (`Contracts/MediaPlayer.md`, `Contracts/NowPlaying.md`) | done on the guest side, with the shared host side: `DynamicMedia` (the `MediaPlayback` contract, the guest's observable `MediaPlayer`, the `VideoPlayer` view and node, `AudioPlayer`, and what's playing, its buttons and background playback), and `RuntimeMedia` (`HostMediaPlayback`, the contract over a host's `MediaPlatform` and `MediaEngine`); the `.audio` capability, with `background`; `examples/ExampleMedia`. The Darwin host plays through `AVPlayer`, shows what's playing and plays on in the background (DarwinAppRuntime's `DarwinMedia`); no other host does yet |
| Text editing (`Contracts/TextEditor.md`) | done on the guest side, with the shared host side: `DynamicText` (the `TextStorage` contract, the guest's observable `TextBuffer`, and the `TextEditor` view and node, for a buffer or a `String` binding), `@FocusState`, `focused` and the keyboard's two modifiers in the frontend, with the `focus` event, and `RuntimeText` (`HostTextStorage`, the contract over a host's `TextPlatform` and `TextEngine`, with `TextCoding`, `TextSearch` and `MemoryTextEngine`); `examples/ExampleText`. No platform host has a text view behind it, so no text has been shown or typed into |
| Clipboard (`Contracts/Clipboard.md`) | done on the guest side, with the shared host side: `DynamicClipboard` (the `Clipboard` contract and the guest's `Pasteboard`), `textSelection` in the frontend, and `RuntimeClipboard` (`HostClipboard`, the contract over a host's `ClipboardPlatform`, and `MemoryClipboard`); `examples/ExampleClipboard`. No platform host has a clipboard behind it, so nothing has reached another app |
| Secrets and sign-in (`Contracts/Secrets.md`) | done on the guest side, with the shared host side: `DynamicSecrets` (the `Secrets` contract and the guest's `Keychain`) with `RuntimeSecrets` (`HostSecrets`, over a host's `SecretStore`), and `DynamicAuthentication` (the `WebAuthentication` contract and the guest's `WebAuthenticationSession`) with `RuntimeAuthentication` (`HostWebAuthentication`, over a host's `WebAuthenticationPresenter`); the `.secrets` capability and the manifest's `authenticationSchemes`; `examples/ExampleSignIn`. No platform host has a keychain or a browser behind it, so no secret has been kept safely and no provider's page shown |
| Background tasks (`Contracts/BackgroundTasks.md`) | done on the guest side, with the shared host side: `DynamicBackgroundTasks` (the `BackgroundTasks` contract, and the guest's `BackgroundTaskScheduler` with its requests, runs and activities), and `RuntimeBackgroundTasks` (`HostBackgroundTasks`, the contract over a host's `BackgroundScheduler`); `backgroundTasks` and its capability in the manifest; a `.background` option for a notification's button, and `wakesApp` for a push; `examples/ExampleBackground`. The Darwin host schedules tasks and holds the app for activities, and starts the guest without a window (DarwinAppRuntime's `DarwinBackgroundTasks`); no other host does yet |
| Notifications (`Contracts/Notifications.md`) | done on the guest side, with the shared host side: `DynamicNotifications` (the `Notifications` and `PushNotifications` contracts, and the guest's `UserNotificationCenter` with its content, triggers, categories, responses and push subscription), and `RuntimeNotifications` (`HostNotifications`, both contracts over a host's `NotificationPresenter`); `remote` and `exactTiming` on the manifest's capability, and Android's `googleServices`; `examples/ExampleNotifications`. The Darwin host shows and schedules them on iOS and macOS, and registers for push (DarwinAppRuntime's `DarwinNotifications`); no other host does yet |
| Defaults (§7.9) | done: `DynamicDefaults` (the `Defaults` contract, the guest's `UserDefaults` and `@AppStorage`), and `HostDefaults` in `RuntimeHost` with a file-backed store; `examples/ExampleDefaults`. The Darwin host keeps the values in a `UserDefaults` suite of the app's own (DarwinAppRuntime's `DarwinDefaults`) |
| Model store (§7.9) | done: `DynamicCoreModel` (the `ModelStore` contracts, and for the guest `RuntimeModelStorage`, `FetchedResults` and `Query` over CoreModel), and `RuntimeCoreModel` (`HostModelStore`, the contracts over any CoreModel backend, with an in-memory provider); `examples/ExampleModel`. The Darwin host keeps stores in Core Data (DarwinAppRuntime's `DarwinModelStore`); the Linux host needs a provider, and Android and the browser a host side of their own |
| Web views (§9.6) | done on the guest side: `DynamicWebKit` (`WebKit` in guest builds) with the `WebContent` contract, `WebPage` and the `WebView` view and node; `examples/ExampleWeb`. The Darwin host implements it over `WKWebView` on iOS and macOS (DarwinAppRuntime's `DarwinWebKit`); no other host does yet |
| OpenGL ES 2.0 for guests, the surface and its input (§8.1, §8.2, §8.6) | done on the guest side and for both wasm engines: `CGLES2` (`gles2.h`), `DynamicGraphics` (`Surface`, `SurfaceDelegate`, `SurfaceEvents`), the `GLSurface` view, and the import shim `CRuntimeGL`, generated with the header by `Scripts/gles2.py`; `examples/ExampleGL`, which draws correctly on Mesa under a test host (`Scripts/test-gl-mesa.sh`). The Darwin host makes the GL context and sends input on iOS and macOS (DarwinAppRuntime's `DarwinGraphics`); no other platform host does yet |

Not in phase one: platform hosts and backends (ObjC, JNI), renderers
(players), the platform packagers (the portable manifest → an iOS
`Info.plist` or an `AndroidManifest.xml`), GL contexts and frame loops,
which are each host's. TCP and UDP are not part of the spec.

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
  `rt_*` C symbols over `NativeRuntime.shared`; `RuntimeWasm`, a package of
  its own (§3), binds a wasm instance's `rt` imports to any `HostRuntime`, normally the same shared one,
  so host objects and wasm objects live in one handle table.
- Each object made by `rt_implement` remembers its `Guest`: the wasm instance
  (`WasmGuest`, called through its exports), native code in the process
  (`NativeGuest`, called through its `rt_dispatch` export), or the host's own
  Swift code once it uses the direct binding (`HostGuest`, §3).
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

- **Host builds of `DynamicRuntime`.** A host links an app's sealed slice
  next to its own Swift code, which uses `DynamicRuntime` for its proxies
  and exports. Both defined `rt_dispatch` and `rt_finalize`, and the host's
  exports went through the C `rt_implement` the slice uses, so the runtime
  took them for the app's. Now:
  - The `GuestExports` package trait (on by default) gates `DynamicRuntime`'s
    `@c(rt_dispatch)` / `@c(rt_finalize)`. Hosts depend on AppRuntime with
    `traits: []`. `guest.py` passes each package's default traits to
    `swiftc`, as SwiftPM does.
  - `Runtime` and `Exported` call through `Runtime.binding`
    (`RuntimeBinding`): the `rt_*` functions (`CRuntimeBinding`) by default,
    or `DirectRuntimeBinding`, which calls a `HostRuntime` as a given guest.
    `NativeRuntime.bindDirectly()` sets it, with `NativeRuntime.host` (a
    `HostGuest`, whose `dispatch` calls `Exported.dispatch`) as the guest.
  - `NativeGuest`, the app, calls the `rt_dispatch` / `rt_finalize` it's
    given: `start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)`.
    With the trait on they default to `DynamicRuntime`'s, so in-process
    guests (this package's tests) need nothing.
  - `HostRuntime` keys each implementation by its guest, so the app's and
    the host's contexts, both numbered from 1, stay apart. Capabilities
    gate only the app: `HostGuest` is unrestricted.
  - The thrown-message hand-off (`Exported.takeDispatchErrorMessage()`) works
    for the host's exports. A sealed slice keeps its own messages, as a wasm
    guest does.
- **Platform minimums.** The package supports macOS 12 / iOS 15, the oldest
  deployment targets current Xcode accepts (`.v10_15` and `.v13` are
  deprecated), so a host can depend on it at its own minimum. Swift
  Concurrency, `TaskLocal` included, back-deploys that far, and the shared
  modules use nothing newer. WasmKit declares macOS 15 / iOS 18, and SwiftPM
  rejects a product whose minimum is higher than its client's even behind a
  package trait, so the WasmKit engine and its tests moved to
  `Packages/RuntimeWasm`, which depends on this package by path. The root
  package exports `ExampleHost` for those tests.
- **SwiftUI frontend** (§9): ported from Swift-iOS6's Embedded SwiftUI, with
  its backend calls replaced by render IR. Identity is positional, with no
  reflection: each composed view's `body` runs in a scope keyed by its
  parent's scope and its place among its siblings, `@State` takes the next
  slot in its scope, and each node the next node ID. Containers, `if`
  branches, `ForEach` elements (by `id`) and `.id(_:)` open their own scopes,
  so a view behind an `if` doesn't shift its siblings. `@State` is
  observable, and one coalescing listener around the whole evaluation drives
  updates; the result is diffed against the last tree, and only changed
  subtrees go out (§9.5). Navigation follows Swift-iOS6: the path is a list
  of link IDs, and pushed levels re-render live each update. Without key
  paths: `@Environment(Model.self)` (not `\.key`), `ForEach(data, id: {…})`
  (a closure), and `@Bindable` through the generated `Bindings`. Not done
  yet: pickers, menus, sheets, alerts, tab views, grids, gestures beyond
  taps, animation, `GeometryReader`.
- **`GuestExecutor.whenIdle`** runs a handler just before control returns to
  the host, after jobs drain; the frontend sends its updates there, so an
  event, a task and a timer all produce one update.
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
- **`Permissions`, `Bundle` and `Application`** are built-ins every host
  provides. Unlike `Clock`, the runtime core doesn't implement them: they're
  `@DynamicRuntime` protocols in `DynamicRuntime`, so a host implements them
  like any contract (`PermissionsProxy.register(MyPermissions.self, in:
  native)`). `HostRuntime` registers their descriptors
  (`BuiltinContracts`) at start, so they resolve before the host registers
  an implementation, and calls fail with `.notFound` until it does. Their
  methods throw `RuntimeError`, so a guest can handle a host without them.
  - Contracts in the `org.pureswift.runtime.` namespace get no `rt.contracts`
    record: apps don't declare what every host provides, and a record would
    land in every app that links `DynamicRuntime`.
  - `Bundle` is `AppBundle` in Swift, so a host that imports Foundation can
    still write `Bundle`.
  - `Permissions` takes a `Capability`, which travels as its raw string. A
    host reports `.denied` for capabilities the app's manifest doesn't
    declare.
  - The delegates take their object first, like the provider contracts'
    (`didChangeState(_:state:)`), and `ApplicationState`'s raw values match
    `UIApplication.State`.
- **Contracts are class-bound** (`protocol BluetoothCentral: AnyObject`). Embedded
  Swift only supports existentials of class-bound protocols, and contract
  parameters such as `BluetoothPeripheral` are existentials. The macro reports a
  missing `AnyObject` with a fix-it. The design's examples omit it.
- **Raw string types.** A contract can declare a `RawRepresentable` type with
  `String` raw values, such as `BluetoothUUID`; it travels as its `rawValue`.
  A macro only sees syntax, so generated code calls `_rtEncode` and
  `_rtDecode…` by name and the compiler picks between each contract's overloads
  and the generic ones in `DynamicRuntime`. A method returning such a type must
  be declared `throws` (anything else is a compile error), and an invalid
  string throws `RuntimeError.thrown`. An invalid callback argument fails the
  incoming call the same way.
- **wasm2c shim.** A host with no slice for its platform translates
  `App.wasm` with WABT's wasm2c. `Scripts/wasm2c-shim.py shim` generates
  the import shim from `rt.h`, and `build` translates, compiles and seals
  the result into a `libapp.a` with the same three exports, the same `rt_*`
  imports and the module's `rt.abi`, `rt.contracts` and `rt.manifest`
  sections, so a host links it like a slice.
  - **`slice` makes a Linux slice, `libapp.so`,** for a bundle with no
    native slice for an architecture: a Linux device has no compiler, so
    this runs where a bundle is built or distributed. `slice --bundle`
    adds it to the bundle: the library, the target in `RTTargets`, and
    `CodeResources` for the files as they now are.
  - The library passes the checks `guest.py` makes of a native one
    (`check_shared`), so a runner loads either. That rules out compiling
    against a libc: built with Ubuntu's headers, the same sources leave
    `__sigsetjmp`, `stderr`, `mmap`, `pthread_mutex_lock` and 12 more
    undefined, hold a `jmp_buf` and a mutex of glibc's sizes, and have
    thread-local storage.
  - So the module, wasm-rt and the shim are compiled freestanding, with
    the package's Swift toolchain, for the triple and flags of the
    target's native slice, and the same support files are sealed in
    (`armv7-eabi.c` for 64-bit division and conversions). Each libc header
    they include is a one-line file including
    `Scripts/support/wasm2c-freestanding.h`, which declares the libc set
    and defines the rest:
    - `calloc` and `realloc` on `malloc`, each block carrying its size;
    - wasm-rt's memory from `malloc` (`WASM_RT_USE_MMAP=0`);
    - no locks and no thread-local storage (`-D_Thread_local=`): the guest
      has one thread;
    - `setjmp` as the compiler's `__builtin_setjmp`, with a trap's reason
      carried beside it, since that resumes with 1. The toolchain's clang
      has none for arm64 ("not supported for the current target"), so
      there the two are a few lines of assembly;
    - rounding as builtins, which are instructions on arm64 and x86_64.
      VFPv3 has none, so on armv7 `floor`, `ceil`, `trunc` and `rint` are
      written out, and agree with libm bit for bit on 4 million inputs;
    - `clock_getres` as one nanosecond, and nothing printed: wasm-rt's
      report of a failed allocation is lost.
  - The generator reads each `RT_IMPORT` and relies on one rule of `rt.h`:
    every pointer parameter is followed by its count. Pointers become
    bounds-checked copies (output arrays are copied in, then back), so a
    call back into the guest that grows its memory can't leave the host
    holding a stale pointer. `rt_method_decl` arrays and their strings are
    converted from the guest's 16-byte layout.
  - `rt_dispatch` places its slots in guest memory with the module's
    `rt_alloc` / `rt_free`. Each export calls the module with its own trap
    target and restores the outer one after, since the guest can call the
    host, which can call the guest again. A trap returns `RT_ERR_THROWN`
    and is written to stderr; the module stays usable.
  - wasm-rt is built with explicit bounds checks and stack depth counting,
    so it installs no signal handlers in the host's process.
  - WASI preview 1 is minimal: stdout and stderr (`RT_WASM2C_WRITE`, which
    a host can define to log), clocks, randomness, empty arguments and
    environment, no files. `proc_exit` traps. A module importing anything
    else is rejected when the shim is built.
  - w2c2, which the Darwin packager's design also names, generates a
    different API; the shim targets WABT's only.
- **Manifest stage** (§7.1–7.3). `App.swift` defines `let app = App(…)`
  with the `AppManifest` library: full Swift for the build machine, no
  Foundation, no dependencies. `guest.py` (`Scripts/manifest.py`) compiles
  it with the library into a throwaway executable and runs it, which prints
  the manifest as JSON with sorted keys, as SwiftPM does with
  `Package.swift`. On macOS it runs under `sandbox-exec` with no network
  and no writes outside its temporary directory; on Linux under `unshare
  --user --net` when unprivileged namespaces are allowed (no network, but
  writes aren't confined), otherwise unsandboxed with a warning.
  - Checks: reverse-DNS `id`; a 1–3 part `version`; a positive `build`;
    every `.localized` key in each language's
    `resources/<language>.lproj/Manifest.strings`; capabilities against
    the contracts' (missing is an error, unused a warning); each platform's
    minimum against its slices' (`ios-arm64`: 13.0; `macos`: 10.15); known
    platforms, no duplicates, Android's `targetSDK` ≥ `minSDK`; an icon
    (a warning without one).
  - Without `--target`, the bundle has the manifest's platforms, leaving out
    targets past their last OS (`ios-armv7` stops at iOS 10.3).
  - `RTCapabilityUsage` maps each capability to its usage text's key in
    `Manifest.strings`. A written-out usage text gets the key
    `RTCapabilityUsage.<capability>`, added to the bundle's copy of every
    language's file. `CFBundleDisplayName` is the development language's
    name, and `RTDisplayNameKey` its key.
  - Every slice embeds the same JSON as `rt.manifest`: a Mach-O section
    (`ld -r -sectcreate __DATA __rt_manifest`), an ELF section added with
    `llvm-objcopy`, or a wasm custom section. The sealed-slice checks read
    it back.
  - With `--manifest`, the flags override its fields, except
    `--capability`, which is an error: capabilities need usage texts.
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
- **Files (§7.9).**
  - **WASI has no files.** §3.3 gave wasm guests preopened directories;
    the `Files` contract replaces them, so one API serves native slices,
    which have no file functions, and browsers, which can't block.
  - **The host side is shared and has no Foundation.** `HostFiles` is the
    contract over `open`, `pread`, `rename`, `readdir`; a host gives it
    the directories' paths. It's in `RuntimeHost`, which now depends on
    `DynamicFiles`.
  - **Every operation is asynchronous**, also for a host that could
    answer at once: work runs on a serial queue and answers on the main
    thread. A host passes `deliver` when its main loop isn't the main
    dispatch queue, and tests pass closures that run at once.
  - **`didFail` carries a code and no message**, unlike the draft. The
    guest's `FileError` is an enum to switch over, with nowhere to keep
    one.
  - **Confinement is by resolved path.** The deepest part of a path that
    exists is resolved, and must still be inside the directory, so a
    symbolic link out of it is refused for reads and for writes.
  - **A replacing write** is a temporary file beside the target and a
    `rename` over it.
  - **Listings sort by UTF-8 bytes**, so every host gives the same order.
  - **`FileManager` collides with Foundation's** where both are imported:
    host-side Swift writes `DynamicFiles.FileManager`.
- **Media players (`Contracts/MediaPlayer.md`, `Contracts/NowPlaying.md`).**
  - **The player design's proposals were taken as they stood,** and its
    seventh question answered by the second design: background playback
    is in.
  - **The guest works out the time.** The host reports a position, a
    timestamp on the guest's clock and a rate; `currentTime` is exact
    when read, and changes for views only at each report.
    `times(every:)` needs nothing more from the host: it's a timer on the
    guest's clock.
  - **The shared host finds every source first,** through
    `HostFiles.path(of:path:)`, which is what the documents design put
    there for this: a picked document plays with no method of its own.
  - **The host answers the system's buttons it can,** on the engine, and
    marks the pause it caused as the user's. Only next and previous cross
    to the guest.
  - **The app never reports elapsed time.** What the system shows as
    playing is what the app said plus what the host knows of the player,
    sent at each change of state.
  - **One now-playing player, the one last described.** Its identifier is
    kept beside the weak reference, so releasing it still clears what was
    shown.
  - **`AudioPlayer`'s closures don't own it:** they hold it unretained,
    since it owns the media player they're set on.
  - **A pause is said once per reason.** An engine that reports the same
    state twice isn't passed on.
- **Text editing (`Contracts/TextEditor.md`).**
  - **`TextEditor` is in `DynamicText`, not the frontend,** which the
    design proposed. An app's `rt.contracts` lists every contract of the
    modules it links, and `AppCompatibility` refuses an app that lists one
    the host lacks. With the view in `DynamicSwiftUI`, every SwiftUI app
    listed the three text contracts: `ExampleUI` and `ExampleMedia` did,
    and no host has them. Focus and the keyboard's modifiers stay in the
    frontend, since they need no contract.
  - **Reads are synchronous.** `length`, `text`, `substring` and the line
    calls answer from the text view's storage, on the main thread, as
    `identifier()` does. Only files and searches answer through a
    callback.
  - **Positions are UTF-16 units,** `Int32` on the wire. The shared host
    clamps them and moves them out of surrogate pairs before an engine
    sees them, by reading the two units around one.
  - **The shared host decides where the selection goes** after the
    guest's edit (`TextPositions`), and says it once: an engine's own
    idea of it isn't reported in between.
  - **A buffer's first text is taken in silently.** A view may be the
    first to use a buffer, in the middle of an update, and what the host
    reports back then mustn't count as a change. The guest converts the
    line breaks of that text itself, so `length` is right before the host
    has it.
  - **`TextEditor(text:)` keeps a buffer of its own** and copies the whole
    text into the binding after each edit. What it pushes to the host
    isn't written back.
  - **`HostFiles.snapshot()`** is new: `Files`' whole-file read and write
    with the grants as they were, for a contract that works off the main
    thread. A text's load and save use it, so a picked document needs no
    method of its own.
  - **A load holds the text weakly.** A load that another replaced, or
    whose buffer was released, answers `cancelled` when its file work
    comes back.
  - **`MemoryTextEngine` is the default,** not an error: a host with no
    text view still holds, edits, searches and saves a guest's texts.
  - **Case folding is per UTF-16 unit,** from the standard library's
    lower-case mapping where that's one unit. No regular expressions.
  - **`TextSelection` has no case for several ranges:** `RangeSet` needs
    macOS 15, and an editor here has one selection.
- **Clipboard (`Contracts/Clipboard.md`).**
  - **No type from another contract's module.** `image(to:)` gives a
    `PasteboardImageType` and not the documents module's `ContentType`,
    which the design had: linking that module would have put the document
    pickers in every copying app's `rt.contracts`. The module depends on
    `DynamicFiles` alone, for `FilePath`.
  - **A copy's completion handler is optional,** and the `async` forms
    share the names. In a synchronous action the plain call drops a
    failure; in `async` code the same call is the `async` one.
  - **The bytes say what an image is,** on the way in and on the way out:
    the type a guest or a platform gives is ignored.
  - **File errors are folded into four:** not permitted and read-only are
    `notAllowed`; missing, a folder and a bad path are `invalidData`.
  - **A platform's completion is heard once.** The shared host drops a
    second answer, since a guest's callback takes one.
  - **`MemoryClipboard` is the default,** not an error: on a host with no
    clipboard, copy and paste work inside the app.
  - **`textSelection` is a modifier with nothing behind it:** no contract
    and no event. It's in the frontend.
- **Secrets and sign-in (`Contracts/Secrets.md`).**
  - **Two modules, each depending on `DynamicRuntime` alone,** so an app
    that keeps a password declares one contract and not the other's.
  - **No stand-in store.** Without a `SecretStore`, `HostSecrets` fails
    every call with `unavailable`. `MemorySecretStore` exists for tests
    and is never chosen by the shared host.
  - **A store is called off the main thread, in order,** on one serial
    queue: a keychain call can block on the user. The store is
    `Sendable`; the callback stays on the main thread.
  - **Limits are the contract's, not the platform's:** 255 bytes of key
    and 16 KB of value everywhere, checked before a store sees them.
  - **A string is its UTF-8,** and a read of bytes that aren't is
    `invalidData`, decided in the guest.
  - **The host gives the redirect.** `scheme:/path` by default; a
    presenter overrides it, as a browser host must. A redirect is
    accepted when it begins with what the presenter gives for a declared
    scheme and no path.
  - **A sign-in is numbered,** so a presenter's completion after a
    cancel, or for a page before, is told from the current one and
    dropped.
  - **Cancelling answers first.** The guest gets `canceledLogin` at once
    and the presenter is told after: a presenter that never completes
    can't leave the app waiting.
  - **`authenticationSchemes` needs no capability,** and each scheme
    must be lower case with a dot, which no scheme of the web's has.
- **Background tasks (`Contracts/BackgroundTasks.md`).**
  - **No new entry point.** A background start is `rt_main`, as any start
    is, and the host's renderer waits for a window. A slice keeps its
    three exports, which `guest.py` checks it has exactly.
  - **Runs and activities are numbers,** not objects: what notifications
    taught about a host reading back the guest's objects.
  - **Embedded Swift has no `MainActor` and no untyped `throws`.** The
    `async` handler is generic over its error, and is `nonisolated(nonsending)`
    so it runs where it's started. In a guest that's the one executor; in
    a host build, where tests run this code, the task is put on the main
    actor, since Swift's own executor would run it on another thread.
  - **And no weak references,** so the scheduler can't hold an activity
    weakly to end it when it's let go. The activity owns a small state
    object the scheduler knows of only while the activity is open.
  - **The guest says who its delegate is with every handler** and every
    activity. Saying it once left a host that had started over deaf.
  - **A repeating request is the shared host's to ask again.** Apple's
    scheduler runs a request once, and the app is started afresh for the
    run, so the intervals are kept in a file.
  - **A request names its task's kind,** and one that names the manifest's
    task as the other kind is `notDeclared`: the platform was told
    something else about it.
- **Notifications (`Contracts/Notifications.md`).**
  - **A host can't cast what the guest hands back.** A record the guest
    made reaches a host method as the guest's proxy, so the host reads it
    through the contract. The design had records the host would read by
    their fields: the record gained methods that say its trigger, and
    categories became calls on `Notifications` between `beginCategories`
    and `endCategories`, with no object. The first test run found it.
  - **Sound, importance and buttons are a category's,** not a
    notification's as Apple has them: Android fixes them per channel, and
    a category is the channel there.
  - **Push is a second contract,** `PushNotifications`, so an app's
    contract list says whether it uses push. The packager then requires
    `remote` in the manifest, and the shared host refuses to register
    without it.
  - **One permission status type.** Settings carry a `PermissionStatus`,
    the built-in `Permissions` contract's. That contract's `status` is
    synchronous and iOS's isn't, so the shared host keeps the last answer.
  - **Requests are checked in the shared host,** before any presenter:
    Foundation's calendar says whether calendar parts ever match. A time
    the clocks skip is the next one they show that day, but 29 February
    isn't 1 March: the matching is strict about the day and lenient about
    the time.
  - **The host's objects live as long as the process.** The guest's
    centre keeps the ones it first asked for, so a reset empties them and
    doesn't replace them.
  - **`RuntimeNotifications` uses Foundation,** for the calendar.
    `RuntimeHost` still doesn't.
  - **Nothing runs the guest in the background.** Every button opens the
    app, and a push with data only doesn't reach a closed app.
- **Documents (`Contracts/Documents.md`).**
  - **A picked document is a directory.** `FileDirectory` became a struct
    with a raw value, so a host can hand out values of its own (256 and
    up) beside the app's five. `Files`, its rules, its errors and every
    contract that takes a directory and a path then serve the user's
    files unchanged. The alternative, a file object with its own read and
    write, would have repeated `Files` and needed a second method in each
    of those contracts.
  - **The grant is an object, and its release is the revocation.** The
    guest's `Document` holds a `DocumentGrant`; when it's released the
    host ends the access. A `FilePath` is a value and can outlive it, and
    then fails with `notPermitted`.
  - **Grants are changed on the main thread and copied per operation.**
    `HostFiles` already copied its file system into each operation's
    closure, so the grant table needs no lock, and an operation that's
    running keeps the grants it started with.
  - **What was picked stays put.** A document's own empty path can't be
    removed or moved, where a directory's empties it. Emptying a folder
    the user picked with one call was too easy to do by accident.
  - **A file alone can't always be replaced atomically.** The user may
    give a file and not its folder, where no temporary file can be made
    beside it. `HostFiles` then writes over it in place.
  - **Permission errors have a code.** `EACCES` and `EPERM` are
    `notPermitted`; they were `unknown`.
  - **The shared host side is its own target,** `RuntimeDocuments`.
    `DynamicDocuments` carries the SwiftUI modifiers, so it depends on the
    frontend, and `RuntimeHost` shouldn't.
  - **The modifiers ask for the picker after the view update,** through
    `GuestExecutor.whenIdle`. A host that answered at once changed the
    app's state while its views were being evaluated, and the screen kept
    the old text. The wasm test found it.
  - **Bookmarks are strings the host keeps,** not bytes: a browser's file
    handle can be stored only in the browser's own database.
  - **Files no longer arrive through `ApplicationDelegate.open(_:url:)`.**
    A guest could do nothing with a path outside its container.
  - **Typed throws and `Task`.** A closure written `() throws(FileError)`
    and handed to `Task { }` threw a garbage error value in a host test
    (Swift 6.4.2). An ordinary throwing closure around the same call is
    right. The guest's API isn't affected; it's worth knowing when
    writing tests.
- **Defaults (§7.9).**
  - **Synchronous**, the one app-data contract that is: every platform's
    small key-value store answers at once, `localStorage` included.
  - **Removing is its own method**, and the setters take a value and
    return whether it was kept, where the draft had `nil` remove a key and
    the setters return nothing. A browser's `setItem` can fail at the
    quota, and the guest should hear of it.
  - **`@AppStorage` is in `DynamicDefaults`, not the SwiftUI module.** It
    needs only Observation, where `Binding` lives. In the frontend it
    would put `Defaults` in every SwiftUI app's `rt.contracts`.
  - **`UserDefaults` is the observable thing.** Each key is one observed
    property of one object, and the list of keys another, so every
    `@AppStorage` on a key and every direct read update together.
  - **Typed values are text.** Embedded Swift parses and prints `Double`,
    and a value comes back with the same bits. Parsing is what needed
    `fma` in the slices (§4, finding 4).
  - **`HostDefaults` takes its store from the host** (`DefaultsStorage`),
    since Apple's and Android's own stores are the right ones there.
    `FileDefaultsStorage`, for Linux, rewrites one file atomically at each
    change, sharing the replace-by-rename of `HostFiles`.
- **Model store (§7.9).**
  - **CoreModel is the API, and a dependency.** `DynamicCoreModel`
    re-exports it; the package now depends on CoreModel 2.11.1 or later,
    and guest builds bring swift-embedded-foundation with it (§4,
    finding 10).
  - **A storage can be used before it's open.** `RuntimeModelStorage` is
    made synchronously, so an app's `Query`s can be made with it at
    launch; the contract says operations wait for the open and fail as it
    did. `open` is the same thing, awaited.
  - **An insert merges**, as CoreModel's does: the properties a record has
    are set and the object's others are left. The draft said "replaces".
  - **The contract has what CoreModel can say, and no more.** Expression
    constants carry their attribute type, so a date isn't taken for a
    number; a to-one's ID and a to-many's IDs are constants of their own;
    there's no list of values, since CoreModel's expressions have none
    (its `IN` is membership in a to-many or a substring test, and its
    `BETWEEN` matches nothing). Composite attributes aren't kept: a model
    with one fails to open.
  - **Reading a record is a call per value, two for a zero.** A null reads
    as false, 0 or `nil`, so only a false or a zero needs `isNull` asked
    as well.
  - **`FetchedResults` stops the app on a record that doesn't decode.** A
    collection's subscript can't throw, and there's no entity to return
    in its place. `element(at:)` throws, for code that would rather.
  - **Requests with custom functions are evaluated in the guest**, on the
    whole entity, with CoreModel's evaluator: a host can't call the guest
    for each object.
  - **`RuntimeModelStorage` is a `ModelStorage` only outside Embedded
    Swift**, where a typed `throws` can't witness the protocol's untyped
    one. The methods are the same; CoreModel's own in-memory storage has
    the same gap.
  - **The adapter works over any `ModelStorage`, and leaves it what only
    a backend can do:** migration, atomic batches (`AtomicModelStorage`,
    until CoreModel has a batch requirement), and both sides of a
    relationship. It does the checking against the model, the ordering,
    the answers on the main thread and the change notices.
  - **`didChange` names more entities than a batch wrote to:** also the
    ones its objects' relationships point at, whose other side changes
    with them. A `Query` on a list's to-dos' count would miss an added
    to-do otherwise.
  - **A host's callback is released on the main thread**
    (`MainThreadHeld`). Carried in a closure to another thread, it was
    released there whenever the main thread had finished with it first,
    and that last release tells the runtime, which isn't thread-safe. The
    model store's tests crashed on it; `HostFiles` had the same fault.
  - **The guest's `async` calls run where they're called from**
    (`nonisolated(nonsending)`, on `withCallback`, `RuntimeModelStorage`
    and `FileManager`). In a guest there's one thread anyway. In host-side
    Swift they used to hop to the pool and make their contract calls
    there, beside whatever the main thread was doing with the runtime.
- **Web views (§9.6).**
  - **A page is a contract object, and the node only places it**, as
    `Surface` and `GLSurface` do. A web view is mostly commands and
    answers (load, go back, run this script, may I follow this link),
    which the render IR has no way to say: its props are state and its
    events have no results. So `WebContent` carries them, with a delegate
    for the page's state, and the `WebView` node has one prop, `page`.
  - **`shouldNavigate` is answered synchronously.** Every engine asks on
    the main thread and can wait, and an async answer would need a
    request to match it to.
  - **The module is its own product**, named `WebKit` in guest builds as
    Apple's is. Inside `DynamicSwiftUI` it would put `WebContent` in every
    SwiftUI app's `rt.contracts`.
  - **`network` is optional for a web view.** `WebContent` requires no
    capability, so bundled HTML needs no `INTERNET` permission. Without
    `network` the host keeps a page off the network and answers a remote
    URL with `WebError.Code.notPermitted`. A contract's metadata can only
    say "requires", so the pairing is a table in `Scripts/manifest.py`,
    which stops the "declared but no contract requires it" warning.
  - **`_RenderNodeView`** is the public way for a module outside the
    frontend to add a node; `WebView` is built on it.
  - **`WebPage` is written against the registrar, without `@Observable`:**
    its properties are read-only to apps, and the macro would generate
    setters and bindings for them.
  - **No retain cycle without weak references.** The host holds the
    delegate, and the page holds the host's object. The delegate is a
    separate object with an unretained reference to the page, which the
    page clears when it's released.
  - **URLs are strings**, as `Link`'s are: guest code has no Foundation.
- **OpenGL ES (§8).**
  - **One table.** `Scripts/gles2.py` holds the 140 functions, each pointer
    parameter marked with how it's used and how many bytes, and the 301
    constants. It generates the guest's header and the hosts' shim, and
    `wasm2c-shim.py` and `guest.py` import it, so the four can't disagree.
    A test compiles the header against the iOS SDK's `ES2/gl.h`: every
    prototype and constant matches.
  - **Typed constants.** `gles2.h` declares constants as `static const`
    with their GL type, so Swift passes `GL_TRIANGLES` where a `GLenum` is
    wanted without a cast. C code that switches on them defines
    `GLES2_CONSTANT_MACROS` first.
  - **`Surface.identifier()` is an `Int32`**, where the draft said `Int64`:
    a node's int prop is a Swift `Int`, 32 bits on wasm32.
  - **`GLSurface` takes the identifier, not the surface.** The view is in
    the SwiftUI frontend, which doesn't depend on `DynamicGraphics`:
    otherwise every SwiftUI app would list `Surface` in `rt.contracts` and
    need the `graphics` capability.
  - **The shim hands GL the guest's memory itself**, after checking bounds,
    where the `rt` imports copy. GL can't call back into the guest, so the
    memory can't move during the call, and vertex and texture uploads
    aren't copied twice.
  - **One shim for both engines** (`CRuntimeGL`). wasm2c output calls its
    typed functions and it calls the `gl*` symbols (`RT_GL_DIRECT`), so
    the slice links like a native one. WasmKit calls it by index
    (`rt_gl_call`) with a table of GL functions the host looks up, so
    `RuntimeWasm` links against no GL.
  - **A host obligation the design didn't have:** a wasm2c slice that
    draws needs `rt_gl_context_generation` from its host, so the shim can
    forget buffer bindings when a GL context is replaced. Without that, a
    guest could keep an attribute "bound" after a context loss and have GL
    read its offset as a host address.
  - **`glGetString`** results are copied into memory from the guest's
    `rt_alloc` and kept for good, since a guest may hold the pointer.
  - **Not done:** validating a draw's indices and counts against buffer
    sizes (§8.1), the `env.gl3` and `env.webgpu` tiers, and the command
    buffer of §8.5.

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
| `ios-simulator` | arm64 none-macho + `x86_64-apple-macos26`, stamped iOS Simulator 13.0 | fat archive; x86_64 objects restamped before sealing (finding 1) |
| `macos` | arm64 none-macho (11.0) + `x86_64-apple-macos14` stamped 10.15 | fat archive |
| `tvos-arm64`, `visionos-arm64` | `arm64-apple-none-macho`, stamped tvOS 13 / visionOS 1 | |
| `watchos-arm64` | `arm64-apple-none-macho`, stamped watchOS 6 | arm64 watches only |
| `linux-arm64`, `android-arm64-v8a` | `aarch64-none-none-elf`; `aarch64-unknown-linux-gnu` for concurrency | see finding 7 |
| `linux-armv7` | `armv7-none-none-eabi`, `-mfloat-abi=hard` | armhf |
| `android-armeabi-v7a` | `armv7-none-none-eabi`, `-mfloat-abi=softfp` | |
| `linux-x86_64`, `android-x86_64` | `x86_64-unknown-none-elf`, CPU `nehalem` (x86-64-v2) | |

Every native slice is one `ld -r` object: in `libapp.a`, or for Linux
linked into `libapp.so` (below). Only `rt_main`,
`rt_dispatch` and `rt_finalize` stay global, and the build fails if:
- any undefined symbol falls outside the §7.5 set;
- the slice has glibc-only references;
- an export or the `rt.abi` section is missing.

A Linux slice is `libapp.so`, linked from the sealed object (`ld.lld
-shared -Bsymbolic -z now -z text --hash-style=both --strip-all`), so a
device installs an app without a compiler or a linker (§7.6). It has no
`libapp.a`: the Linux host is the only one that takes these slices, and it
loads them. The sealed object, with its symbols and the guest's debug
info, stays in the build directory as `app.o`. The build fails if the
library:
- names another library (`DT_NEEDED`);
- leaves a symbol undefined outside the §7.5 set, or exports anything but
  the three guest exports;
- doesn't bind as it loads, or has relocations in code;
- runs code as it loads (`DT_INIT`, `DT_INIT_ARRAY`), or has thread-local
  storage;
- lacks the `rt.abi` section, or holds another manifest.

It's stripped: 435 KB for `ExampleApp` on arm64, where a `libapp.a` of the
same object, with its symbols and the guest's debug info, is 991 KB. Its sections aren't
collected (`--gc-sections` saves about 4%), because nothing refers to `rt.abi`.
The Android slices have no `libapp.so`: that host links the slice into a
library of its own.

`App.wasm` is checked for the reactor exports, and for imports outside
`rt`, WASI preview 1 and the GL functions of `gles2.py`. A native slice's
`gl*` references are checked against the same list.
The bundle step:
- with `--manifest App.swift`, evaluates the manifest (below) and runs its
  checks; otherwise validates contract capabilities against `--capability`
  (§7.3);
- writes `Info.plist` (`RTTargets`, `RTABIVersion`, `RTCapabilities`,
  `RTContracts`, and with a manifest `RTPlatforms`, `RTCapabilityUsage`,
  `RTCapabilityOptions`, `RTDisplayNameKey`, `RTIcon`,
  `RTPlatformExtras`);
- writes per-file SHA-256 hashes to `_CodeSignature/CodeResources` (unsigned).

### Findings

Each of these needs a decision, or is verified only as far as noted:

1. **Apple deployment floors.** The toolchain's Embedded stdlib for OS
   triples requires iOS 18 / macOS 14, and it has none for tvOS, watchOS or
   visionOS. Embedded code makes no OS calls, so the slices are built for
   `none-macho` (same Darwin calling convention) and stamped with the
   platform at seal time. They link, but haven't run on devices.

   The simulator's linker rejects objects stamped for iOS devices
   ("building for 'iOS-simulator', but linking in object file … built for
   'iOS'"), so `ios-simulator` is its own slice, stamped
   `PLATFORM_IOSSIMULATOR` (7). x86_64 has no simulator stdlib, so its
   objects are built for macOS like the `macos` slice, and `guest.py`
   rewrites the `LC_BUILD_VERSION` of each object and runtime archive member
   to the simulator before `ld -r`: ld won't mix platforms, and `vtool`
   can't grow an object's load commands. Both architectures link into an
   iOS Simulator executable. The arm64 one ran in the iOS 26 simulator
   (`rt_dispatch` with an unknown context returned `RT_ERR_NOT_FOUND`); the
   x86_64 one hasn't run, since Apple silicon simulators run arm64.
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
   It also seals the conversions between 64-bit integers and `Float` /
   `Double` (`__aeabi_l2f`, `__aeabi_d2lz` and the rest), which VFP has no
   instructions for: `ExampleGL` turned a nanosecond timestamp into
   seconds, and the slice didn't seal. They work on the values' bits, with
   the base calling convention the EABI gives every `__aeabi_*` helper, and
   agree with a 64-bit host's conversions over 32 million values.
   Every ELF slice also seals `fma` and `fmaf` there. The stdlib's parser
   of numbers from text (`Double("0.1")`) calls `fma`, which arm64 has an
   instruction for and x86-64-v2 and armv7 don't; `ExampleDefaults`, which
   reads a `Double` setting, didn't seal for macOS x86_64. The sealed one
   is exact, working on the bits in 128-bit integer arithmetic, and agrees
   with arm64's instruction and with libSystem's `fma` on 114 million
   inputs each (random bits, cancellation, subnormals, overflow, ties).
   Apple slices take `fma` from libSystem.
   Every ELF slice also seals `sqrt` and `sqrtf` (`Scripts/support/math.c`):
   Swift's `squareRoot()` calls `sqrt`, which isn't in the §7.5 set. Each
   compiles to the architecture's square root instruction. Apple slices get
   libm from libSystem.
5. **x86_64** uses the x86-64-v2 baseline (SSE4.2, POPCNT; Android x86_64
   requires it), so `ceil` compiles to an instruction instead of a libm call.
6. **`arc4random_buf`.** The Embedded stdlib calls it to seed hashing.
   It is in the allowed set as "random", but **musl doesn't provide it**
   (1.2.5). On a musl distro the runner has to define it, and export it
   for the `libapp.so` it loads. `ExampleGL`'s `libapp.so` did load under
   musl in Alpine 3.22 with a host that doesn't, but only because Mesa had
   brought `libbsd` into the process, which has one. A runner's own
   definition is found first, so it shouldn't leave this to chance.
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
   library with fixed flags, plus its package's default traits as defines.
   Traits a dependent package sets on its dependencies aren't read either.
10. **CoreModel in a guest.** What `ExampleModel` needed:
    - CoreModel's manifest adds swift-embedded-foundation only when
      `SWIFT_EMBEDDED=1` is in the environment, so `guest.py` reads the
      package graph with it set. Macro plugins are built without it: they
      run on the build machine, where that dependency asks for a newer
      macOS than the package does.
    - Embedded Swift doesn't import `_Concurrency` implicitly, and
      CoreModel's sources don't import it themselves. Every Swift module
      of a slice that has the concurrency runtime now gets
      `-import-module _Concurrency`.
    - swift-embedded-foundation's default trait
      `FloatingPointParsingShims` defines `Float16` parsing, which doesn't
      compile for x86_64 Apple targets. `guest.py` leaves that trait off
      (`GUEST_DISABLED_TRAITS`).
    - armv7 ELF slices seal two more helpers (`Scripts/support/armv7-eabi.c`):
      `__aeabi_ldivmod`, the signed 64-bit division CoreModel's integer
      arithmetic and Foundation's dates need, and `floor`. Both agree with
      a 64-bit host on about 100 million inputs.

## 5. Tests

- `RuntimeABITests`: signatures, slots, keys, metadata encoding.
- `DynamicRuntimeMacrosTests`: model, expansion shape and contract-rule
  diagnostics.
- `RuntimeCoreTests`: registry, calls, `rt_implement`, finalization and
  re-entrancy, `List`, `Clock` and `ManualClock`, errors, validation.
- `DynamicRuntimeTests`: the example app as a native slice, end to end
  (every wire type, callbacks both ways, throws, lists, identity, capability
  gating, leak check).
- `LinkedSliceTests` (`Packages/LinkedSlice`): a host built like a platform
  host, with AppRuntime's traits off, linked with one app library, which
  the environment picks: `ExampleApp` or `ExampleUI`, as its sealed macOS
  slice or translated by wasm2c (skipped until it's built; see the
  package's manifest). The same tests pass for all four. `ExampleApp` runs
  through the library's exports with no capabilities while the host keeps
  its own; the host's exports belong to `HostGuest`; nothing leaks on
  either side. `ExampleUI` is driven like a player, as in the WasmKit test. With the trait on, the same
  link fails with duplicate `rt_dispatch` / `rt_finalize` under SwiftPM's
  native build system. Swift Build, the default, lists the duplicates but
  doesn't fail the link.
- `Scripts/test_wasm2c_shim.py`: reading `rt.h` and rejecting what the
  generator has no rule for; the generated wrappers; a hand-written module
  and a fake C host for string copies both ways, slots, an out-of-bounds
  offset, a trap after a re-entrant call, and use after traps; rejecting
  unsupported imports. Needs WABT.
  - Linux slices: the module builds as `libapp.so` for the three Linux
    targets and passes `guest.py`'s checks, with none of a libc's own
    names undefined; a module that draws asks for the host's GL; one
    without `rt.abi`, and a target that isn't Linux, are refused; a bundle
    gains a slice, its target and its hashes, and a slice it has isn't
    replaced.
  - The freestanding rounding functions against the machine's libm.
  - With `APPRUNTIME_DOCKER_TESTS=1`, the fake host is built to load a
    library (`-DHOST_LOADS -rdynamic`) and runs each slice in Docker on
    its own architecture, arm64, x86_64 and armv7, the last two emulated:
    the same checks pass, the two traps included. That's the only run of
    `setjmp` in its three forms.
- `RuntimeWasmTests` (`Packages/RuntimeWasm`): the import shim with
  hand-written WAT guests, and the same example app as `App.wasm` (built by
  `Scripts/build-wasm.sh ExampleApp`; skipped without it), including
  `rt.contracts` validation and its async checks: tasks run before
  `rt_main` returns, sleeps resume when the test advances a `ManualClock`,
  and cancellation before and during a sleep. Embedded only: in host tests
  Swift's own executor runs guest code.
- Contract test targets (`DynamicBluetoothTests`, `DynamicLocationTests`,
  …): names, capabilities, keys and signatures of the provider contracts, and
  their async wrappers against fake Swift hosts through `NativeRuntime`:
  permissions, one-shot calls, streams starting and stopping, failures,
  cancellation, and handle and export leak checks.
- `DynamicObservationTests`: tracking, nested tracking, the mask fast path
  and high indices, coalescing listeners, registrars released before their
  observers, `Bindings`, and the macro's expansion.
- `AppManifestTests`: the manifest's JSON for the design's example, left
  out optional fields, escaping and property list values.
  `Scripts/test_manifest.py`: `.strings` parsing, every manifest check,
  default targets, the `Info.plist` keys and usage strings, evaluating the
  example manifest, and on macOS a manifest whose file write the sandbox
  blocks.
- `DynamicUITests`: the IR's byte format: round trips, determinism, payloads
  and IDs, and rejection of every truncation and malformed input.
- `DynamicSwiftUITests`: the frontend against a recording sink: first tree,
  minimal updates, `@Observable` models and bindings, identity behind `if`s
  and across `ForEach` reorders, lazy rows, navigation, the environment,
  appearance; and through `NativeRuntime` with a host `Renderer`.
- `RuntimeWasmTests` also runs the example UI app (`examples/ExampleUI`) as
  `App.wasm` (built by `Scripts/build-wasm.sh ExampleUI`; skipped without
  it), driven like a player: taps, typing, lazy rows, push and pop.
- `DynamicRuntimeTests/AsyncHelperTests`: `EventStream` buffering,
  failure, and termination on finish, cancellation and release;
  `withCallback`; `PendingCallbacks` ordering; `EventSubscribers` fan-out.
- `DynamicRuntimeTests/BuiltinContractTests`: the `Permissions`, `Bundle`
  and `Application` built-ins against fake hosts, calls before a host
  implements them, and their descriptors against `BuiltinContracts`.
- `DynamicFilesTests`: the file contracts' keys and signatures, `FilePath`,
  and the guest's `FileManager` against a scripted host: what each call
  asks, answers and failures, an answer of the wrong kind, a second
  answer, answers out of order, awaiting, and cancellation.
- `RuntimeHostTests/HostFilesTests`: `HostFiles` on real files in a
  temporary directory: atomic replacement, appends, ranges, the transfer
  limit, sorted listings, attributes, making and removing trees, moves and
  copies, the read-only bundle, paths that would leave their directory,
  symbolic links out of it, names that differ by case, and `temporary`
  emptied at start; then the guest's `FileManager` through `NativeRuntime`
  to those files, with completion handlers and with `await`. The async
  tests run on the main actor, so the guest's calls and the host's answers
  share a thread as they do in a host; they crashed now and then on Linux
  before the callback was released on the main thread and the `async`
  calls stayed on their caller's actor (§3, the model store's notes).
  Both suites also pass on Linux (`swift:6.4-noble` in Docker).
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleFiles`
  against `HostFiles` too, as `App.wasm`, a sealed macOS slice and wasm2c
  output, and check the files it leaves.
- `DynamicMediaTests`: the media contract's keys and signatures, and the
  guest's `MediaPlayer` against a scripted host: each kind of source, what
  a host says it plays, state following the host's reports, the time
  worked out from the clock, observation, settings kept in range and sent
  once, a seek answered once, the end and a failure, a released player,
  what's playing and its buttons, the `VideoPlayer` node and a view that
  keeps its own player, `AudioPlayer`'s loops and delegate, and the
  streams: events to every listener in order, an awaited seek, and ticks
  while it plays.
- `RuntimeMediaTests`: `HostMediaPlayback` over players the test keeps in
  memory and real files, from the guest through `NativeRuntime`: a file
  found before the engine sees it, a picked document and one no longer
  held, a URL's scheme and the network, a host with no players, a `play()`
  that came early, time on the guest's clock, seeks replaced and dropped,
  the end as a pause, the background, a player that plays on and holds
  the app, interruptions and unplugged headphones, what's shown as playing
  and when, the player last described, the buttons the host answers and
  the two it passes on, and a node finding its engine.
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleMedia`
  against `HostMediaPlayback`, as `App.wasm`, a sealed macOS slice and
  wasm2c output. Both suites also pass on Linux (Swift 6.4.2, arm64, in
  Docker).
- `DynamicTextTests`: the text contracts' keys and signatures, and the
  guest's `TextBuffer` against a scripted host: what it asks, a first
  text sent once, state following the host's reports, a released buffer,
  a load's answers of every kind, a save's format, and where a search
  starts.
- `RuntimeTextTests`: `HostTextStorage` over texts the test types into
  and real files, from the guest through `NativeRuntime`: a text made
  when first used, lines, surrogate pairs, the guest's edits and their
  undo, the selection after each, the user's typing, line breaks on the
  way in, a new text, files in each encoding with and without a mark, a
  file that isn't UTF-8, the platform's own encoding, a text too long, a
  picked document, a load replaced, a released buffer, a save's bytes and
  failures, typing during a save, searching each way, replacing all as
  one edit, the async forms, the node, a buffer first used by its view,
  and a binding with its selection. `TextCoding` and `TextPositions` are
  tested by themselves. `DynamicSwiftUITests` has focus as state and the
  keyboard's modifiers.
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleText`
  against `HostTextStorage`, as `App.wasm`, a sealed macOS slice and
  wasm2c output, and check the file it saves. The four suites also pass
  on Linux (Swift 6.4.2, arm64, in Docker).
- `DynamicClipboardTests`: the clipboard contracts' keys and signatures,
  and the guest's `Pasteboard` against a scripted host: an image's bytes,
  looking, what each copy asks, a copy's answer, pasted text and links,
  and a pasted image as bytes and as a file, with answers from a newer
  host.
- `RuntimeClipboardTests`: `HostClipboard` over a clipboard the test
  fills as another app would, and real files, from the guest through
  `NativeRuntime`: an app's own clipboard with no platform, copied text
  and links, looking without reading, pasted text as it is, a refusal, a
  platform that asks first and one that answers twice, what's too large,
  an image from its bytes and from its file, a picked document copied
  from and pasted into, an image pasted as bytes and into a file, and the
  async forms. `DynamicSwiftUITests` has `textSelection`.
  `RuntimeWasmTests` and `LinkedSliceTests` run
  `examples/ExampleClipboard` against `HostClipboard`, as `App.wasm`, a
  sealed macOS slice and wasm2c output, and check the file it pastes.
  The three suites also pass on Linux (Swift 6.4.2, arm64, in Docker).
- `DynamicSecretsTests` and `DynamicAuthenticationTests`: both contracts'
  keys and signatures, and the guest's `Keychain` and
  `WebAuthenticationSession` against scripted hosts: what each asks, no
  secret, bytes that aren't a string, and answers from a newer host.
- `RuntimeSecretsTests`: `HostSecrets` over a store in memory, from the
  guest through `NativeRuntime`: no store, secrets kept by key and
  replaced, keys sorted, the limits on keys and values, a store's
  refusals, work done in the order asked, and the async forms.
- `RuntimeAuthenticationTests`: `HostWebAuthentication` over a browser
  the test plays: a native host's redirect and a browser host's, the
  redirect returned whole, what isn't `https` or declared, a redirect
  that wasn't waited for, one sign-in at a time, a browser that answers
  twice, the app closing the page, a late answer, and a cancelled task.
  `AppManifestTests` and `Scripts/test_manifest.py` cover `.secrets` and
  `authenticationSchemes`.
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleSignIn`
  against both shared hosts, as `App.wasm`, a sealed macOS slice and
  wasm2c output. The four suites also pass on Linux (Swift 6.4.2, arm64,
  in Docker).
- `DynamicBackgroundTasksTests`: the background contract's keys and
  signatures, and the guest's `BackgroundTaskScheduler` against a scripted
  host: what a request asks, a task with no handler, lists and
  withdrawals, the system's switch, a run reaching its handler and being
  completed once, a run told it's out of time, activities ended, let go of
  and expired, a host that holds no app, and the `async` forms: a handler
  that returns or throws, one cancelled when time runs out, and a block
  held by an activity.
- `RuntimeBackgroundTasksTests`: `HostBackgroundTasks` over a scheduler the
  test keeps in memory, from the guest through `NativeRuntime`: requests
  checked against the manifest's tasks, the system told how a run went, a
  run that overstays its grace, a run before the app listens, repeating
  requests asked again and remembered in a file across a restart, and
  activities that hold the app until they end or run out.
  Both suites also pass on Linux (Swift 6.4.2, arm64, in Docker).
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleBackground`
  against `HostBackgroundTasks`, as `App.wasm`, a sealed macOS slice and
  wasm2c output, with the test running the task as the system would.
- `DynamicNotificationsTests`: the notification contracts' keys and
  signatures, and the guest's `UserNotificationCenter` against a scripted
  host: settings and what asking passes, a request written into a record
  with each kind of trigger, categories and their buttons, lists and
  removals, how one is shown while the app is in front, responses and
  deliveries through one delegate, a response that waits for a listener,
  push registration and a changed address, awaiting, streams and
  cancellation.
- `RuntimeNotificationsTests`: `HostNotifications` over a notification
  centre the test keeps in memory, from the guest through `NativeRuntime`:
  nothing shown until the user allows it, a refusal that stays, the
  built-in permission as the same one, requests as the centre receives
  them, requests that can't fire, the pending limit, categories set
  together, a notification that fires while the app runs, the response
  that started the app, push with and without the manifest's leave, and a
  centre with no push service. And the triggers' arithmetic: the next
  weekday, a leap day, a year that has gone, a time the clocks skip.
  Both suites also pass on Linux (Swift 6.4.2, arm64, in Docker).
  `RuntimeWasmTests` and `LinkedSliceTests` run
  `examples/ExampleNotifications` against `HostNotifications`, as
  `App.wasm`, a sealed macOS slice and wasm2c output.
- `DynamicDocumentsTests`: the document contracts' keys and signatures,
  content types and their forms on the wire, and the guest's
  `DocumentPicker` and `Document` against a scripted host: one file, many,
  a folder, cancelling, failures, exports that are saved, copied or
  cancelled, bookmarks, the documents an app is opened with as a closure
  and as a stream, awaiting, cancellation, a grant released when its
  document is, and `fileImporter` and `fileExporter` in a view graph.
- `RuntimeDocumentsTests`: `HostDocuments` over a test's presenter and real
  files in a temporary directory, from the guest's `DocumentPicker` and
  `FileManager` through `NativeRuntime`: reading and writing a picked
  file, a read-only one, a folder and what's under it, access ending when
  the document is let go, one picker at a time, a host with no pickers,
  exports, bookmarks and their limit, and documents that wait for the
  guest to listen. `HostFilesTests` covers the grants themselves: a file
  as an empty path, a folder, read-only grants, a link out of a folder,
  directories nobody granted, and a file written in place where nothing
  can be made beside it.
  These suites and `DynamicFilesTests` also pass on Linux (Swift 6.4.2,
  arm64, in Docker; as root there, so the write-in-place test doesn't meet
  a folder it can't write to).
  `RuntimeWasmTests` and `LinkedSliceTests` run `examples/ExampleDocuments`
  against `HostDocuments` and real files, as `App.wasm`, a sealed macOS
  slice and wasm2c output.
- `DynamicDefaultsTests`: the contract's keys and signatures, and the
  guest's `UserDefaults` and `@AppStorage` against a store in memory:
  what missing values read as, round trips of every type (a `Double`'s
  bits, `Int`'s limits), values of another kind, removal, a refused value,
  observation of a key and of the key list, enums by raw value, bindings,
  and a view that follows its settings.
- `RuntimeHostTests/HostDefaultsTests`: `FileDefaultsStorage` on a real
  file: values there after another launch, the file's exact bytes, no
  write for an unchanged value, the size limit, a damaged file moved
  aside, a failed write changing nothing (skipped as root, which a
  read-only directory doesn't stop); then the guest's `UserDefaults`
  through `NativeRuntime` across launches. `RuntimeWasmTests` launches
  `examples/ExampleDefaults` twice as `App.wasm` on one settings file, and
  `LinkedSliceTests` runs it as a sealed macOS slice and wasm2c output.
- `DynamicCoreModelTests`: the guest's `RuntimeModelStorage`,
  `FetchedResults` and `Query` through `NativeRuntime` to `HostModelStore`
  over CoreModel's in-memory backend. Every attribute type there and back,
  and nulls as nulls; about five hundred requests (comparisons of each
  type, string operators and options, relationships and key paths through
  them, arithmetic, compounds, sorts, limits and offsets) answered the
  same as the backend answers them itself; results read a record at a
  time, and unchanged by later writes; functions run in the guest; a
  batch applied in order, merging, and one that can't be applied changing
  nothing; requests and models the store refuses; observers told once per
  batch, in every storage of a store; a `Query` that follows writes,
  changes of its request and what its predicate reaches, and keeps its
  results when a fetch fails; a storage used before it's open; a store
  kept between openings, migrated, refused or emptied; no provider;
  the same code through `ModelStorage` on this and on CoreModel's own
  storage; the host's objects given what they can't hold; and every
  handle released at the end.
  `RuntimeWasmTests` runs `examples/ExampleModel` as `App.wasm` across two
  launches on one store, and `LinkedSliceTests` as a sealed macOS slice
  and wasm2c output on a store that has objects in it already.
- `RuntimeFormattingTests`: the formatting contracts over Swift Foundation,
  on macOS and Linux (Debian 13 in Docker): through the proxies as a guest
  calls them; locales and their separators, currencies and clocks; every
  number style, fraction digits and grouping, integers exact past 2^53;
  date styles, patterns, templates, parsing, time zones and relative
  dates; unknown styles and time zones replaced and logged; the user's locale from `LC_ALL`, `LANG` and `LANGUAGE` outside
  Apple platforms; formatters shared by configuration. Foundation differs
  between the two in three places, which `RuntimeFormatting` hides: Linux
  has no `RelativeDateTimeFormatter` (`Date.AnchoredRelativeFormatStyle`
  is used), its `NumberFormatter` loses integers past 2^53
  (`IntegerFormatStyle`), and it groups the POSIX locale's digits.
- `RuntimeNetworkingTests`: the networking contracts over `URLSession`, on
  macOS and Linux (Debian 13 in Docker), against a `URLProtocol` that
  answers without a network: a round trip with headers, a body and the
  session's headers; chunks as they arrive; upload progress; redirects
  followed and refused; Basic challenges answered with a host-made
  credential, and those the guest can't answer; a refused response;
  cancelling before and after `resume`; an invalid URL; invalidation,
  which completes what's left and lets every delegate go; failures mapped
  to `NetworkError`; URL parsing, resolving and query decoding; and every
  configuration setting. Every guest callback is checked to arrive through
  `deliver` on the main queue. swift-corelibs-foundation's URLSession
  differs from Apple's in ways `RuntimeNetworking` hides or a test works
  around: it has no expensive or constrained networks and never waits for
  connectivity (those settings do nothing); it disregards a refused
  response and goes on loading (the task is cancelled and its data
  dropped); it sets a task's state after calling back (the task keeps the
  guest's view); it answers only Basic challenges with a credential and
  stops the process for others (other methods get the default handling);
  its TLS `NSURLError…` constants are one off Apple's (codes are matched
  as `URLError.Code`s); and the server trust and client certificate
  methods are unavailable. It also stops the process when a `URLProtocol`
  redirects, and retries an answered challenge over its own HTTP
  protocol, so on Linux the tests ask the session's delegate about
  redirects, challenges and progress directly; the end-to-end versions run
  on macOS.
- `DynamicWebKitTests`: the web contracts' keys and signatures; `WebPage`
  against a stand-in engine through `NativeRuntime`: the host page made on
  first use, state following the delegate, observation, the navigation
  decider, scripts answered out of order and awaited, and the host page
  destroyed with the guest's; the `WebView` node, and a `WebView(url:)`
  keeping one page across updates. `RuntimeWasmTests` and
  `LinkedSliceTests` run `examples/ExampleWeb` the same way, as
  `App.wasm`, a sealed macOS slice and wasm2c output.
- `CRuntimeGLTests`: the GL shim against a recording GL and a block of
  "guest memory": pointers passed without copying, reads and writes at and
  past the end, sizes that would wrap, strings without a terminator, shader
  source arrays, image sizes by format, type and alignment, results whose
  size GL decides, the buffer rules for attributes and draws, a deleted
  buffer, a new context, and calls by index.
- `DynamicGraphicsTests`: the `Surface` contracts' keys and signatures, key
  codes, `SurfaceEvents`' pointer and key state, and a surface through
  `NativeRuntime`, every scalar type both ways.
- `Scripts/test_gles2.py`: the generated files are current, the table's
  shape, and the header against the iOS SDK's. `test_wasm2c_shim.py` also
  runs a hand-written module's GL calls against a fake GL in C (results,
  `glGetString`, a trap, a replaced context), and seals one.
- `RuntimeWasmTests` also covers the `env.gl` imports with a WAT guest, and
  runs `examples/ExampleGL` as `App.wasm` (built by `Scripts/build-wasm.sh
  ExampleGL`; skipped without it) against a recording GL: the first frame's
  shaders, buffer and draw, later frames, a touch, a key, and a lost
  context.
- `Scripts/test-gl-mesa.sh`: `ExampleGL` on a real GL, Mesa's software
  renderer in Docker with an EGL pbuffer. A C host
  (`Scripts/hosts/gl-mesa-host.c`) with just enough of `rt.h` starts the
  app and calls its surface delegate. Each run draws the triangle upright,
  upside down after π seconds, and again in a context made after the first
  was destroyed, and the frames of all three are byte-identical. It isn't
  part of `swift test`: it needs Docker and WABT.
  - The three runs: the Linux slice, `libapp.so`, loaded as a runner loads
    it, by a host built without the app (`-DHOST_LOADS -rdynamic`);
    `App.wasm` as a Linux slice (`wasm2c-shim.py slice`), loaded the same
    way; and `App.wasm` translated and compiled into the host against the
    image's libc.
  - The same host built without `-rdynamic` exports no `rt.h`, and the
    library must fail to load in it: `undefined symbol: rt_class`.
  - It passes on Ubuntu 24.04 for arm64, and under Docker's emulation
    for x86_64 and armv7 (`GL_MESA_PLATFORM`), which is the only run the
    x86_64 and armv7 native slices have had. On emulated armv7 Mesa's
    llvmpipe crashes while drawing, with no library loaded too, so that
    platform uses softpipe.
  - The native slice for arm64, with the same host built there, drew the
    same bytes under musl in Alpine 3.22 (finding 6), and the same bytes
    as the slice linked into the host as a `libapp.a`, when the slice
    still had one. The wasm2c slices haven't run under musl.
- `Scripts/test_guest_shared.py`: what `libapp.so`'s checks refuse, from
  `llvm-objdump` output written in the test, and from libraries linked
  from C for the three Linux architectures: a clean guest passes, and a
  constructor, thread-local storage, another export, another import and
  another manifest are each refused. The linked half is skipped without
  the toolchain.
- `LinkedSliceTests` runs `ExampleGL` too (`APPRUNTIME_LINKED_PRODUCT=
  ExampleGL`), as its sealed macOS slice and through wasm2c. The host's GL
  is `CFakeGL`, generated by `gles2.py`: every `gl*` function, writing
  down its arguments. Both engines produce the same 32 calls for the first
  frame, argument for argument.

## 6. Next

1. Settle the review items in §3 (allocator exports, guest error messages).
2. Players that interpret the render IR (§9.4): the iOS 13+ / macOS SwiftUI
   player, an adapter for AndroidSwiftUI's Compose interpreter, and
   Swift-iOS6's backend for iOS 6. More of the vocabulary (animations,
   gestures beyond taps, `GeometryReader`, images from the app's assets),
   and per-view re-evaluation. Pickers, sheets, alerts, confirmation
   dialogs, tab views, grids, forms, menus, toolbars, disclosure groups,
   links, swipe actions, search, shapes, date pickers, context menus and
   pull to refresh are in.
3. Manifest packager: `App.swift` → Info.plist / AndroidManifest, signing.
4. Hosts and backends (ObjC, JNI, Linux `rt-host`), in their own
   repositories or later here (Linux only).
   - The Linux host (LinuxAppRuntime) built an executable per app from
     the slice's `libapp.a`, which the slice no longer has. One runner
     that loads `libapp.so` is next there: it exports `rt.h`, checks the
     app at launch, and installs by copying the thinned bundle. Until
     then it can't take a bundle built from here.
5. `Surface` in the other hosts (`Documentation/Contracts/Graphics.md`):
   the GL context, the frame loop and input. The Darwin host has them
   (DarwinAppRuntime's `DarwinGraphics`).
6. The `GameController` and `Audio` contracts, which are drafts
   (`Documentation/Contracts/`).
7. `WebContent` in the other hosts (`Documentation/Contracts/WebKit.md`):
   Android's `WebView`, and WPE on Linux (the Darwin host has `WKWebView`), where its child
   processes inside the launcher's sandbox are the open question. Then
   messages from a page's scripts to the app.
8. App data (§7.9) in the hosts. The model store needs a provider in
   the Linux host (`Documentation/Contracts/Persistence.md`):
   CoreModel-SQLite, with the stored model and the migration rules, as
   the Darwin host's `DarwinModelStore` has for `CoreDataModel`; then
   Android's and the browser's own host side, and the conformance vectors
   they'd check themselves with. In CoreModel: `@Entity` under Embedded
   Swift, a batch requirement on `ModelStorage`, `CoreDataModel` answering
   as the reference does, and the reference's own string bugs
   (`Persistence.md`, "Not checked yet"). And `Files` and `Defaults` in
   the other hosts: registering `HostFiles` and `HostDefaults` in the
   Linux host, and Android's and the browser's own. The Darwin host has
   them (DarwinAppRuntime's `DarwinFiles` and `DarwinDefaults`).
9. Pickers in the other hosts (`Documentation/Contracts/Documents.md`):
   the picker service and its descriptors in the Linux host; Android's and
   the browser's own host side. Each also turns the bundle's
   `RTDocumentTypes` into its own entries. The Darwin host has them
   (DarwinAppRuntime's `DarwinDocuments`), without iOS file coordination
   yet. Two things in the design are from the platforms' documentation and
   need a test: which export mode on iOS leaves the app with access, which
   the iOS Simulator confirmed and a device hasn't yet, and what Landlock
   does with a descriptor the picker service opened. Then sharing a file and opening
   one in another app, which the design leaves out.
10. Notifications in the other hosts (`Documentation/Contracts/Notifications.md`):
   the notification service in the Linux shell, which holds scheduled
   requests and each app's categories; Android's and the browser's own
   host side, where a push is built from the `rt.` keys. The Darwin host
   has them (DarwinAppRuntime's `DarwinNotifications`), tried on the iOS
   Simulator but not with APNs, and without the time-sensitive
   entitlement yet. None of the platform behaviour in the design has been
   checked on a device. Then an alarm that rings until answered, which
   the design leaves out and the planned Clocks app needs.
11. Background work in the other hosts (`Documentation/Contracts/BackgroundTasks.md`):
   the background service in the Linux host, and Android's own host side
   over `WorkManager`. Each needs a renderer that can be made before
   there's a window, and to start the app for a `.background` button and
   for a push when the manifest says `wakesApp`. The Darwin host has them
   (DarwinAppRuntime's `DarwinBackgroundTasks`), but no system has run a
   task or started its guest in the background yet: the iOS Simulator
   runs none, so it needs a device. `AppInfo` doesn't read
   `RTBackgroundTasks`, `RTCapabilityOptions` or `RTDocumentTypes` yet, so
   each host reads them itself.
12. Media in the other hosts (`Documentation/Contracts/MediaPlayer.md`,
   `NowPlaying.md`): a GStreamer engine and MPRIS in the Linux host, where
   the H.264 decoder is the distro's to ship; Android's and the browser's
   own host side. Each host's renderer shows a `VideoPlayer` node's
   engine. The Darwin host has them (DarwinAppRuntime's `DarwinMedia`),
   tried with MP3 and WAV on the iOS Simulator but not with video or on a
   device, and a muted player there still takes the sound from other
   apps. Then a
   queue for gapless albums, which both designs leave out.
13. Text in the hosts (`Documentation/Contracts/TextEditor.md`): a
   `TextPlatform` and engine over `UITextView` and `NSTextView` in the
   Darwin host, over Cacao's text view in the Linux host, and Android's
   and the browser's own host side, which need an undo history of their
   own. Each host's renderer shows a `TextEditor` node's engine, honours
   `focused`, and reports `focus`. Nothing has been typed into a real
   text view, so undo grouping, input methods and large files are
   untested. Then styled text, for syntax colouring.
14. The clipboard in the hosts (`Documentation/Contracts/Clipboard.md`):
   a `ClipboardPlatform` over `UIPasteboard` and `NSPasteboard` in the
   Darwin host, over the compositor's selection in the Linux host, and
   Android's and the browser's own host side. Each host's renderer makes
   `textSelection` text selectable. What each platform does when an app
   reads, the alert on iOS above all, is from documentation. Then a
   `PasteButton` node, which is the only way past that alert.
15. Secrets and sign-in in the hosts
   (`Documentation/Contracts/Secrets.md`): a `SecretStore` over Keychain
   Services in the Darwin host, with the marker that empties it after a
   reinstall; over the Secret Service in the Linux host, with the sandbox
   keeping guests off the session bus; and Android's and the browser's
   own host side. A `WebAuthenticationPresenter` over
   `ASWebAuthenticationSession`, and the system's browser with a scheme
   handler on Linux. Each host reads `RTAuthenticationSchemes`, which
   `AppInfo` doesn't yet. Nothing here has met a real provider.
