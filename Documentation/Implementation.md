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
| Guest builds: sealed native slices, `App.wasm` reactor, universal bundle (§7.5) | done: `Scripts/guest.py` and wrappers |
| Provider contracts: Bluetooth, Location, URL/HTTP | declared: `DynamicBluetooth`, `DynamicLocation`, `DynamicNetworking`; the platform hosts implement them |
| Number and date formatting | declared: `DynamicFormatting`; `RuntimeFormatting` implements `LocaleInfo`, `NumberFormat` and `DateFormat` over Swift Foundation for any host written in Swift, on Apple platforms and Linux. The Linux host registers it; the Darwin host has its own `DarwinFormatting`, which it's a port of |
| Guest executor and `Clock` contract (§5.4, §7.4) | done: `GuestExecutor`, `RuntimeClock`, `HostClock`; runs in `App.wasm` and every native slice (arm64 ELF needs `Scripts/fetch-embedded-linux.sh`) |
| `Permissions`, `Bundle` and `Application` built-ins (§7.4) | declared: `Permissions`, `AppBundle`, `Application` in `DynamicRuntime`; tested against fake hosts |
| Async wrappers over the provider contracts (§6.2.1) | done: `EventStream`, `withCallback`, and an `Async…` wrapper per contract; tested against fake hosts |
| Observation stopgap (§5.3) | done: `DynamicObservation`, `ObservationMacros` (`Observation` in guest builds) |
| SwiftUI frontend, render IR and renderer contract (§9) | done: `DynamicSwiftUI` (`SwiftUI` in guest builds), `DynamicUI`, `Documentation/RenderIR.md`; no players |
| wasm2c import shim (§11) | done: `Scripts/wasm2c-shim.py` (WABT's wasm2c); `ExampleApp` and `ExampleUI` pass through it |
| Files (§7.9) | done: `DynamicFiles` (the `Files` contract and the guest's `FileManager`), and `HostFiles` in `RuntimeHost`, the contract over POSIX calls for the Darwin and Linux hosts; `examples/ExampleFiles`. The Darwin host registers it on iOS and macOS (DarwinAppRuntime's `DarwinFiles`). Android and the browser need their own host side |
| Defaults (§7.9) | done: `DynamicDefaults` (the `Defaults` contract, the guest's `UserDefaults` and `@AppStorage`), and `HostDefaults` in `RuntimeHost` with a file-backed store; `examples/ExampleDefaults`. The Darwin host keeps the values in a `UserDefaults` suite of the app's own (DarwinAppRuntime's `DarwinDefaults`) |
| Model store (§7.9) | done: `DynamicCoreModel` (the `ModelStore` contracts, and for the guest `RuntimeModelStorage`, `FetchedResults` and `Query` over CoreModel), and `RuntimeCoreModel` (`HostModelStore`, the contracts over any CoreModel backend, with an in-memory provider); `examples/ExampleModel`. No host keeps a store on disk yet: the Darwin and Linux hosts need a provider each, and Android and the browser a host side of their own |
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

Every native slice is one `ld -r` object in `libapp.a`. Only `rt_main`,
`rt_dispatch` and `rt_finalize` stay global, and the build fails if:
- any undefined symbol falls outside the §7.5 set;
- the slice has glibc-only references;
- an export or the `rt.abi` section is missing.

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
  dates; the user's locale from `LC_ALL`, `LANG` and `LANGUAGE` outside
  Apple platforms; formatters shared by configuration. Foundation differs
  between the two in three places, which `RuntimeFormatting` hides: Linux
  has no `RelativeDateTimeFormatter` (`Date.AnchoredRelativeFormatStyle`
  is used), its `NumberFormatter` loses integers past 2^53
  (`IntegerFormatStyle`), and it groups the POSIX locale's digits.
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
- `Scripts/test-gl-mesa.sh`: `ExampleGL` on a real GL, Mesa's llvmpipe in
  Docker with an EGL pbuffer. A C host (`Scripts/hosts/gl-mesa-host.c`)
  with just enough of `rt.h` starts the app and calls its surface
  delegate. The sealed Linux slice and the wasm2c build each draw the
  triangle upright, upside down after π seconds, and again in a context
  made after the first was destroyed; their frames are byte-identical. It
  isn't part of `swift test`: it needs Docker and WABT.
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
   each Swift host (`Documentation/Contracts/Persistence.md`):
   `CoreDataModel` on Apple platforms, CoreModel-SQLite on Linux, each
   with the stored model and the migration rules; then Android's and the
   browser's own host side, and the conformance vectors they'd check
   themselves with. In CoreModel: `@Entity` under Embedded Swift, and a
   batch requirement on `ModelStorage`. And `Files` and `Defaults` in
   the other hosts: registering `HostFiles` and `HostDefaults` in the
   Linux host, and Android's and the browser's own. The Darwin host has
   them (DarwinAppRuntime's `DarwinFiles` and `DarwinDefaults`).
