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
| `DynamicFiles` | The app's files and its bundle's: the `Files` contract and the guest's `FileManager`. `RuntimeHost` has `HostFiles`, the host side over POSIX calls | yes |
| `DynamicMedia` | Media players: a song, a podcast or a video the host decodes and shows. The `MediaPlayback` contract, the guest's `MediaPlayer`, `VideoPlayer` and `AudioPlayer`, what's playing for the lock screen, and playing on in the background | yes |
| `RuntimeMedia` | `HostMediaPlayback`: the media contract over a host's own players | host |
| `DynamicCalendar` | The user's calendars and events, as the system keeps them: EventKit's place. The `Calendars` contract and the guest's `EventStore`, `Event` and `RecurrenceRule` | yes |
| `RuntimeCalendar` | `HostCalendars`: the calendar contract over a host's own store, and a store in memory that expands repeating events | host |
| `DynamicSecrets` | An app's secrets, kept encrypted by the system: a token, a password. The `Secrets` contract and the guest's `Keychain` | yes |
| `RuntimeSecrets` | `HostSecrets`: the secrets contract over a host's own store | host |
| `DynamicAuthentication` | Signing in on a page the system's browser shows: the `WebAuthentication` contract and the guest's `WebAuthenticationSession` | yes |
| `RuntimeAuthentication` | `HostWebAuthentication`: the sign-in contract over a host's own browser | host |
| `DynamicClipboard` | The system's clipboard, for an app's own Copy and Paste: text, a link, an image. The `Clipboard` contract and the guest's `Pasteboard` | yes |
| `RuntimeClipboard` | `HostClipboard`: the clipboard contract over a host's own clipboard, with image files | host |
| `DynamicText` | Text the host holds and the user edits: a file in an editor, a message. The `TextStorage` contract, the guest's `TextBuffer`, and the `TextEditor` view | yes |
| `RuntimeText` | `HostTextStorage`: the text contract over a host's own text views, with files, encodings, line endings and search | host |
| `DynamicBackgroundTasks` | Running while the app isn't in front: tasks the system starts from time to time, and time to finish something. The `BackgroundTasks` contract and the guest's `BackgroundTaskScheduler` | yes |
| `RuntimeBackgroundTasks` | `HostBackgroundTasks`: the background contract over a host's own scheduler | host |
| `DynamicNotifications` | Notifications the system shows for the app, now or scheduled, with buttons, and pushes from the app's server: the `Notifications` and `PushNotifications` contracts and the guest's `UserNotificationCenter` | yes |
| `RuntimeNotifications` | `HostNotifications`: the notification contracts over a host's own notification centre | host |
| `DynamicDocuments` | The user's files, through the platform's pickers: the `Documents` contract, the guest's `DocumentPicker`, `Document` and `ContentType`, and SwiftUI's `fileImporter` and `fileExporter`. A picked file is a directory `DynamicFiles` reaches | yes |
| `RuntimeDocuments` | `HostDocuments`: the documents contracts over a host's own pickers, granting each pick in `HostFiles` | host |
| `DynamicDefaults` | Small settings kept across launches: the `Defaults` contract, the guest's `UserDefaults` and `@AppStorage`. `RuntimeHost` has `HostDefaults`, with a file-backed store | yes |
| `DynamicCoreModel` | A model store behind [CoreModel](https://github.com/PureSwift/CoreModel): the `ModelStore` contracts, and for the guest `RuntimeModelStorage`, `FetchedResults` and `Query` | yes |
| `RuntimeCoreModel` | `HostModelStore`: the model store's contracts over any CoreModel backend, for hosts written in Swift | host |
| `RuntimeFormatting` | `HostFormattingModule`: the formatting contracts (`LocaleInfo`, `NumberFormat`, `DateFormat`) over Swift Foundation, for hosts written in Swift on Apple platforms and Linux | host |
| `RuntimeNetworking` | `HostNetworkingModule`: the networking contracts (`HTTPSession`, `HTTPTask`, `HTTPRequest`, `URL` and the rest) over Swift Foundation's `URLSession`, for hosts written in Swift on Apple platforms and Linux | host |
| `DynamicWebKit` | Web views (`WebKit` in guest builds): the `WebContent` contract, the observable `WebPage`, and the `WebView` view | yes |
| `CGLES2` | `gles2.h`: OpenGL ES 2.0 under WebGL 1 rules, as a guest calls it. Generated by `Scripts/gles2.py` | C, freestanding |
| `DynamicGraphics` | The `Surface` a guest draws on, its frames and pointer and key input | yes |
| `CRuntimeGL` | The wasm engines' side of a guest's GL imports: bounds checks and the WebGL buffer rules. Generated by `Scripts/gles2.py` | host, C |
| `AppRuntime`, `bundle-runtime`, `CBundleRuntime` | Linux bundle model, launcher and sandbox | Linux |

## A contract

```swift
import DynamicRuntime

@DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
public protocol BluetoothCentral: AnyObject {
    static func make(_ delegate: BluetoothCentralDelegate) -> Self
    func state() -> Int32
    func scan(services: [String], allowDuplicates: Bool)
}
```

The macro generates `BluetoothCentralProxy` (calls through `rt_call`), the descriptor
and an `rt.contracts` record, plus adapters that export a Swift
implementation to the runtime. Guest code uses `BluetoothCentralProxy.make(delegate)`;
a Swift host registers `BluetoothCentralProxy.register(MyCentral.self, in: registrar)`.

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

`examples/ExampleUI` is a fuller app. The Darwin host's SwiftUI player
renders the IR on iOS and macOS (DarwinAppRuntime's `DarwinUI`).

`examples/ExampleGL` draws with OpenGL ES 2.0 in a `Surface` placed by a
`GLSurface` view, and takes pointer and key input
([Graphics](Documentation/Contracts/Graphics.md)). The Darwin host runs it
on iOS and macOS (DarwinAppRuntime's `DarwinGraphics`), and
`Scripts/test-gl-mesa.sh` draws it on Mesa in Docker and checks the pixels.

`examples/ExampleFiles` is a notebook kept as text files: it reads its
bundle, and saves, lists, opens and deletes notes with the guest's
`FileManager` ([Files](Documentation/Contracts/Files.md)). The Darwin host
runs it on iOS and macOS (DarwinAppRuntime's `DarwinFiles`).

`examples/ExampleMedia` is a small music player: it plays the songs in its
bundle one after another, says what's playing so the system can show it,
answers next and previous, and plays on in the background
([Media players](Documentation/Contracts/MediaPlayer.md),
[Now playing](Documentation/Contracts/NowPlaying.md)). The Darwin host
plays it on iOS and macOS (DarwinAppRuntime's `DarwinMedia`); in the
tests, players kept in memory stand in.

`examples/ExampleText` is a small editor: it loads a text from its bundle
into a buffer the host holds, says where the caret is, finds and replaces,
undoes and saves ([Text editing](Documentation/Contracts/TextEditor.md)).
The Darwin host shows it in a `UITextView` or `NSTextView`
(DarwinAppRuntime's `DarwinText`); in the tests, the test types into texts
kept in memory.

`examples/ExampleClipboard` copies a sum, a link and its logo, says what
there is to paste without reading it, and pastes text, a link and an image
([Clipboard](Documentation/Contracts/Clipboard.md)). The Darwin host copies
and pastes through the system's pasteboard (DarwinAppRuntime's
`DarwinClipboard`); in the tests, the test keeps one.

`examples/ExampleSignIn` is an account with a provider: it shows the
provider's page in the system's browser, checks the reply, and keeps the
token in the keychain ([Secrets and sign-in](Documentation/Contracts/Secrets.md)).
No host has a keychain or a browser behind it yet, so the tests play both.

`examples/ExampleCalendar` is a month's agenda: it lists each occurrence
of what's on, adds a weekly meeting, moves one occurrence and cancels the
rest ([Calendar events](Documentation/Contracts/Calendars.md)). No host
has a calendar store behind it yet, so the tests keep the events in
memory.

`examples/ExampleBackground` is a feed that keeps itself fresh: it
registers a task the system may run while the app is closed, asks for it
every quarter of an hour, and asks for time to finish a save
([Background tasks](Documentation/Contracts/BackgroundTasks.md)). The
Darwin host schedules its task and holds the app for the save on iOS and
macOS (DarwinAppRuntime's `DarwinBackgroundTasks`); in the tests, the
test runs its task as the system would.

`examples/ExampleNotifications` is a set of kitchen timers: it asks the
user's leave, schedules a notification for when each timer ends, answers
the notification's buttons, and registers for pushes
([Notifications](Documentation/Contracts/Notifications.md)). The Darwin
host shows its notifications on iOS and macOS (DarwinAppRuntime's
`DarwinNotifications`); in the tests, it runs against a centre kept in
memory.

`examples/ExampleDocuments` is a small text editor for the user's own
files: it opens one with `fileImporter`, or the one it's launched with,
saves back to it, saves a copy where the user says, and lists a folder
([Documents](Documentation/Contracts/Documents.md)). The Darwin host shows
the system's pickers for it on iOS and macOS (DarwinAppRuntime's
`DarwinDocuments`); in the tests, the test answers for the user.

`examples/ExampleDefaults` is a settings screen whose values survive a
relaunch, with `@AppStorage`
([Defaults](Documentation/Contracts/Defaults.md)). The Darwin host keeps
them in a `UserDefaults` suite of the app's own (DarwinAppRuntime's
`DarwinDefaults`).

`examples/ExampleModel` keeps to-dos in lists in a model store, written
against CoreModel, with `Query`s that keep the screen current
([Persistence](Documentation/Contracts/Persistence.md)). The Darwin host
keeps them in Core Data (DarwinAppRuntime's `DarwinModelStore`).

`examples/ExampleWeb` is a small browser around a `WebView`: guest code
says `import WebKit`, shows a `WebPage`, follows its title and progress,
decides its navigations and runs scripts in it
([Web views](Documentation/Contracts/WebKit.md)). The Darwin host runs it
over `WKWebView` on iOS and macOS (DarwinAppRuntime's `DarwinWebKit`).

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

### Loading a slice on Linux

A Linux slice is `libapp.so`, not `libapp.a`, so a device installs an app
by copying files: it needs a runner, and no compiler or linker. The runner
loads the library and finds the three guest exports:

```c
void *app = dlopen("lib/linux-arm64/libapp.so", RTLD_LAZY | RTLD_LOCAL);
rt_status (*app_main)(void) = dlsym(app, "rt_main");
```

The library names no other library. The runner's process supplies what it
leaves undefined: the `rt_*` functions, which the runner exports
(`-rdynamic`), a few libc calls, and GLES 2.0 for an app that draws. So the
same file loads under glibc and musl, and a new runner needs no relink. It
binds every symbol as it loads, so a runner that lacks one refuses the app,
by name. `Scripts/test-gl-mesa.sh` loads `ExampleGL` this way; the rules
are in [DynamicRuntime.md](Documentation/DynamicRuntime.md) §7.5 and §7.6.

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
either way, `ExampleFiles` the notebook, with real files in a temporary
directory, `ExampleDocuments` the text editor, with the test answering its
pickers, `ExampleNotifications` the timers, with the test keeping the
notification centre, `ExampleBackground` the feed, with the test running
its task, `ExampleMedia` the music player, with the test standing in for
the players, `ExampleText` the editor, with the test typing into its
texts, `ExampleClipboard` the copying and pasting, with the test keeping
the clipboard, `ExampleSignIn` the account, with the test playing the
browser, `ExampleCalendar` the agenda, with its events in memory, `ExampleDefaults` the settings screen, with a real settings
file, `ExampleModel` the to-dos, with CoreModel's in-memory store,
`ExampleWeb` the browser, with the test standing in for the
engine, and `ExampleGL` the one that draws, against a GL that writes down
what it's asked.

For Linux, `slice` makes `libapp.so`, the slice a runner loads, for a
bundle with no native slice for an architecture, and adds it to the bundle:

```sh
Scripts/wasm2c-shim.py slice --bundle org.example.app --target linux-arm64
```

It's compiled freestanding with the Swift toolchain, like a native slice,
so it names no library and loads under any libc.

`Scripts/wasm2c-shim.py sources` stops before compiling and gathers the C
files, for a build with another toolchain. A module that draws gets the GL
shim too, and its host then defines `rt_gl_context_generation`
([Graphics](Documentation/Contracts/Graphics.md)).

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
