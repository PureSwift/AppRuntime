// swift-tools-version:6.4
import PackageDescription
import CompilerPluginSupport

/// Targets marked as shared must compile both as full Swift and as Embedded
/// Swift (`--swift-sdk swift-6.4.2-RELEASE_wasm-embedded`). Embedded mode is
/// selected by the Swift SDK, not here, so the same targets also build for
/// host tests.
let package = Package(
    name: "AppRuntime",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        // Shared: C ABI, wire model, guest library and macros.
        .library(name: "CRuntime", targets: ["CRuntime"]),
        .library(name: "RuntimeABI", targets: ["RuntimeABI"]),
        .library(name: "DynamicRuntime", targets: ["DynamicRuntime"]),
        // Shared: runtime core with the Swift-registry backend.
        .library(name: "RuntimeCore", targets: ["RuntimeCore"]),
        .library(name: "RuntimeNative", targets: ["RuntimeNative"]),
        // Host only: what every native host shares (the app's keys, the
        // startup checks, modules and the generic built-ins).
        .library(name: "RuntimeHost", targets: ["RuntimeHost"]),
        // Shared: portable provider contracts (declarations; hosts implement them).
        .library(name: "DynamicBluetooth", targets: ["DynamicBluetooth"]),
        .library(name: "DynamicDevice", targets: ["DynamicDevice"]),
        .library(name: "DynamicLocation", targets: ["DynamicLocation"]),
        .library(name: "DynamicMotion", targets: ["DynamicMotion"]),
        .library(name: "DynamicNetworking", targets: ["DynamicNetworking"]),
        .library(name: "DynamicNFC", targets: ["DynamicNFC"]),
        .library(name: "DynamicFormatting", targets: ["DynamicFormatting"]),
        .library(name: "DynamicFiles", targets: ["DynamicFiles"]),
        // Shared: the user's files, through the platform's pickers, and the
        // SwiftUI modifiers that show them.
        .library(name: "DynamicDocuments", targets: ["DynamicDocuments"]),
        // Shared: text the host holds and the user edits, and the
        // `TextEditor` view that shows it.
        .library(name: "DynamicText", targets: ["DynamicText"]),
        // Host only: the text contract over a host's own text views.
        .library(name: "RuntimeText", targets: ["RuntimeText"]),
        // Shared: the user's address book, as the Contacts framework has it.
        .library(name: "DynamicContacts", targets: ["DynamicContacts"]),
        // Host only: the contacts contract over a host's own address book.
        .library(name: "RuntimeContacts", targets: ["RuntimeContacts"]),
        // Shared: the photos and videos the system keeps for the user, as
        // PhotoKit has them, and the `PhotoView` that shows one.
        .library(name: "DynamicPhotos", targets: ["DynamicPhotos"]),
        // Shared: downloads to a file and uploads from one, which the host
        // moves, and the system can carry on.
        .library(name: "DynamicTransfers", targets: ["DynamicTransfers"]),
        // Host only: the transfers contract over a host's own engines.
        .library(name: "RuntimeTransfers", targets: ["RuntimeTransfers"]),
        // Host only: the photos contract over a host's own library.
        .library(name: "RuntimePhotos", targets: ["RuntimePhotos"]),
        // Shared: the camera: a preview, photos, and video with sound.
        .library(name: "DynamicCamera", targets: ["DynamicCamera"]),
        // Host only: the camera contract over a host's own cameras.
        .library(name: "RuntimeCamera", targets: ["RuntimeCamera"]),
        // Shared: the user's calendars and events, as EventKit has them.
        .library(name: "DynamicCalendar", targets: ["DynamicCalendar"]),
        // Host only: the calendar contract over a host's own store.
        .library(name: "RuntimeCalendar", targets: ["RuntimeCalendar"]),
        // Shared: the system's store for an app's secrets, as a keychain.
        .library(name: "DynamicSecrets", targets: ["DynamicSecrets"]),
        // Host only: the secrets contract over a host's own store.
        .library(name: "RuntimeSecrets", targets: ["RuntimeSecrets"]),
        // Shared: signing in on a page the system's browser shows.
        .library(name: "DynamicAuthentication", targets: ["DynamicAuthentication"]),
        // Host only: the sign-in contract over a host's own browser.
        .library(name: "RuntimeAuthentication", targets: ["RuntimeAuthentication"]),
        // Shared: the system's clipboard, for an app's own Copy and Paste.
        .library(name: "DynamicClipboard", targets: ["DynamicClipboard"]),
        // Host only: the clipboard contract over a host's own clipboard.
        .library(name: "RuntimeClipboard", targets: ["RuntimeClipboard"]),
        // Shared: media players: a song, a podcast or a video the host
        // decodes and shows, with what's playing and background playback.
        .library(name: "DynamicMedia", targets: ["DynamicMedia"]),
        // Host only: the media contract over a host's own players.
        .library(name: "RuntimeMedia", targets: ["RuntimeMedia"]),
        // Shared: a map the host draws, in MapKit for SwiftUI's shape.
        .library(name: "DynamicMapKit", targets: ["DynamicMapKit"]),
        // Host only: the maps contract over the service a host is built with.
        .library(name: "RuntimeMaps", targets: ["RuntimeMaps"]),
        // Shared: running while the app isn't in front: tasks the system
        // starts, and time to finish.
        .library(name: "DynamicBackgroundTasks", targets: ["DynamicBackgroundTasks"]),
        // Host only: the background contract over a host's own scheduler.
        .library(name: "RuntimeBackgroundTasks", targets: ["RuntimeBackgroundTasks"]),
        // Shared: notifications the system shows for the app, and pushes
        // from the app's server.
        .library(name: "DynamicNotifications", targets: ["DynamicNotifications"]),
        // Host only: the notification contracts over a host's own
        // notification centre.
        .library(name: "RuntimeNotifications", targets: ["RuntimeNotifications"]),
        // Host only: the documents contracts over whatever shows a host's
        // pickers, with grants made in `HostFiles`.
        .library(name: "RuntimeDocuments", targets: ["RuntimeDocuments"]),
        .library(name: "DynamicDefaults", targets: ["DynamicDefaults"]),
        // Shared: OpenGL ES 2.0 for guests (§8), and the surface it draws to.
        .library(name: "CGLES2", targets: ["CGLES2"]),
        .library(name: "DynamicGraphics", targets: ["DynamicGraphics"]),
        // Host only: the wasm engines' side of a guest's GL imports.
        .library(name: "CRuntimeGL", targets: ["CRuntimeGL"]),
        // Shared: Observation stopgap, render IR and renderer contract, and the
        // SwiftUI frontend (§5.3, §9). Guest builds name the Observation and
        // SwiftUI modules `Observation` and `SwiftUI`.
        .library(name: "DynamicObservation", targets: ["DynamicObservation"]),
        .library(name: "DynamicUI", targets: ["DynamicUI"]),
        .library(name: "DynamicSwiftUI", targets: ["DynamicSwiftUI"]),
        // Shared: web views (`WebKit` in guest builds): the `WebContent`
        // contract, `WebPage` and the `WebView` view.
        .library(name: "DynamicWebKit", targets: ["DynamicWebKit"]),
        // Shared: the model store behind CoreModel (§7.9): its contracts, and
        // the guest's storage, lazy results and Query.
        .library(name: "DynamicCoreModel", targets: ["DynamicCoreModel"]),
        // Host only: the model store's contracts over any CoreModel backend.
        .library(name: "RuntimeCoreModel", targets: ["RuntimeCoreModel"]),
        // Host only: the formatting contracts over Swift Foundation.
        .library(name: "RuntimeFormatting", targets: ["RuntimeFormatting"]),
        // Host only: the networking contracts over Swift Foundation's URLSession.
        .library(name: "RuntimeNetworking", targets: ["RuntimeNetworking"]),
        // Linux: bundle model and sandboxing launcher.
        .library(name: "AppRuntime", targets: ["AppRuntime"]),
        .executable(name: "bundle-runtime", targets: ["BundleRuntime"]),
        // Build machine: the types App.swift manifests use (§7.1).
        .library(name: "AppManifest", targets: ["AppManifest"]),
        // Example guest app. Scripts/guest.py builds its slices and bundle.
        .library(name: "ExampleApp", type: .static, targets: ["ExampleApp"]),
        // The example app's contracts, for the linked-slice tests.
        .library(name: "ExampleContracts", targets: ["ExampleContracts"]),
        // Example UI guest app (§9). Scripts/guest.py builds its slices.
        .library(name: "ExampleUI", type: .static, targets: ["ExampleUI"]),
        // Example GL guest app (§8): a surface drawn with OpenGL ES 2.0.
        .library(name: "ExampleGL", type: .static, targets: ["ExampleGL"]),
        // Example web guest app: a small browser around a WebView.
        .library(name: "ExampleWeb", type: .static, targets: ["ExampleWeb"]),
        // Example files guest app: a notebook kept as text files.
        .library(name: "ExampleFiles", type: .static, targets: ["ExampleFiles"]),
        // Example text guest app: a small editor over a text the host holds.
        .library(name: "ExampleText", type: .static, targets: ["ExampleText"]),
        // Example contacts guest app: an address book, searched and changed.
        .library(name: "ExampleContacts", type: .static, targets: ["ExampleContacts"]),
        // Example camera guest app: a viewfinder that saves to the user's photos.
        .library(name: "ExampleCamera", type: .static, targets: ["ExampleCamera"]),
        // Example photos guest app: a gallery of the user's photos.
        .library(name: "ExamplePhotos", type: .static, targets: ["ExamplePhotos"]),
        // Example calendar guest app: a month's events, added and changed.
        .library(name: "ExampleCalendar", type: .static, targets: ["ExampleCalendar"]),
        // Example sign-in guest app: signs in with a provider and keeps the token.
        .library(name: "ExampleSignIn", type: .static, targets: ["ExampleSignIn"]),
        // Example transfers guest app: downloads the host moves, some of
        // them carried on while the app is closed.
        .library(name: "ExampleTransfers", type: .static, targets: ["ExampleTransfers"]),
        // Example notes guest app: folders, notes and a note in a split view.
        .library(name: "ExampleNotes", type: .static, targets: ["ExampleNotes"]),
        // Example maps guest app: places on a map and in a list.
        .library(name: "ExampleMaps", type: .static, targets: ["ExampleMaps"]),
        // Example clipboard guest app: copies and pastes text, a link and an image.
        .library(name: "ExampleClipboard", type: .static, targets: ["ExampleClipboard"]),
        // Example media guest app: a music player that says what's playing.
        .library(name: "ExampleMedia", type: .static, targets: ["ExampleMedia"]),
        // Example background guest app: a feed the system refreshes.
        .library(name: "ExampleBackground", type: .static, targets: ["ExampleBackground"]),
        // Example notifications guest app: timers that notify when they end.
        .library(name: "ExampleNotifications", type: .static, targets: ["ExampleNotifications"]),
        // Example documents guest app: a text file the user picks, edited
        // in place and saved as a copy.
        .library(name: "ExampleDocuments", type: .static, targets: ["ExampleDocuments"]),
        // Example settings guest app: UserDefaults and @AppStorage.
        .library(name: "ExampleDefaults", type: .static, targets: ["ExampleDefaults"]),
        // Example model guest app: to-dos in a model store, with CoreModel.
        .library(name: "ExampleModel", type: .static, targets: ["ExampleModel"]),
        // Example host contracts, for tests in nested packages (Packages/).
        .library(name: "ExampleHost", targets: ["ExampleHost"]),
    ],
    traits: [
        .trait(
            name: "GuestExports",
            description: "DynamicRuntime defines the rt_dispatch and rt_finalize exports. Guests need it; a host that links an app's native slice turns it off, because the slice defines them."
        ),
        .default(enabledTraits: ["GuestExports"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0"..<"605.0.0"),
        .package(url: "https://github.com/PureSwift/Bluetooth.git", from: "8.2.1"),
        .package(url: "https://github.com/PureSwift/CoreModel.git", from: "2.11.1"),
    ],
    targets: [

        // MARK: - Shared (Embedded Swift compatible)

        .target(
            name: "CRuntime"
        ),
        // Generated by Scripts/gles2.py, as is CRuntimeGL.
        .target(
            name: "CGLES2"
        ),
        .target(
            name: "CRuntimeGL",
            dependencies: ["CGLES2"]
        ),
        .target(
            name: "RuntimeABI",
            linkerSettings: [
                // Embedded String comparison and hashing need Unicode tables.
                .linkedLibrary("swiftUnicodeDataTables", .when(platforms: [.wasi])),
            ]
        ),
        .macro(
            name: "DynamicRuntimeMacros",
            dependencies: [
                "RuntimeABI",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),
        .macro(
            name: "ObservationMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "DynamicObservation",
            dependencies: ["ObservationMacros"]
        ),
        .target(
            name: "DynamicSwiftUI",
            dependencies: ["DynamicRuntime", "DynamicObservation", "DynamicUI"]
        ),
        .target(
            name: "DynamicCoreModel",
            dependencies: [
                "DynamicRuntime",
                "DynamicObservation",
                .product(name: "CoreModel", package: "CoreModel"),
            ]
        ),
        .target(
            name: "RuntimeCoreModel",
            dependencies: [
                "DynamicCoreModel",
                "DynamicRuntime",
                "RuntimeHost",
                "RuntimeNative",
                .product(name: "CoreModel", package: "CoreModel"),
            ]
        ),
        .target(
            name: "DynamicWebKit",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicUI"]
        ),
        .target(
            name: "DynamicRuntime",
            dependencies: [
                "CRuntime",
                "RuntimeABI",
                "DynamicRuntimeMacros",
            ]
        ),
        .target(
            name: "RuntimeCore",
            dependencies: [
                "RuntimeABI",
            ]
        ),
        .target(
            name: "RuntimeNative",
            dependencies: [
                "CRuntime",
                "RuntimeCore",
                "DynamicRuntime",
            ]
        ),
        .target(
            name: "RuntimeHost",
            dependencies: [
                "CRuntime",
                "RuntimeABI",
                "DynamicRuntime",
                "DynamicFiles",
                "DynamicDefaults",
                "RuntimeNative",
            ]
        ),

        // MARK: - Contracts

        .target(
            name: "DynamicDevice",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicDevice"
        ),
        .testTarget(
            name: "DynamicDeviceTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicDevice", "RuntimeNative"]
        ),
        .target(
            name: "DynamicBluetooth",
            dependencies: [
                "DynamicRuntime",
                .product(name: "Bluetooth", package: "Bluetooth"),
                .product(name: "BluetoothGATT", package: "Bluetooth"),
            ],
            path: "Contracts/DynamicBluetooth"
        ),
        .testTarget(
            name: "DynamicBluetoothTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicBluetooth", "RuntimeNative"]
        ),
        .target(
            name: "DynamicLocation",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicLocation"
        ),
        .testTarget(
            name: "DynamicLocationTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicLocation", "RuntimeNative"]
        ),
        .target(
            name: "DynamicMotion",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicMotion"
        ),
        .testTarget(
            name: "DynamicMotionTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicMotion", "RuntimeNative"]
        ),
        .target(
            name: "DynamicNetworking",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicNetworking"
        ),
        .testTarget(
            name: "DynamicNetworkingTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicNetworking", "RuntimeNative"]
        ),
        .target(
            name: "DynamicNFC",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicNFC"
        ),
        .testTarget(
            name: "DynamicNFCTests",
            // RuntimeNative supplies the rt_* symbols the proxies link against.
            dependencies: ["DynamicNFC", "RuntimeNative"]
        ),
        .target(
            name: "DynamicUI",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicUI"
        ),
        .target(
            name: "DynamicFormatting",
            dependencies: ["DynamicRuntime", "DynamicObservation"],
            path: "Contracts/DynamicFormatting"
        ),
        .target(
            name: "DynamicFiles",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicFiles"
        ),
        .target(
            name: "DynamicDefaults",
            dependencies: ["DynamicRuntime", "DynamicObservation"],
            path: "Contracts/DynamicDefaults"
        ),
        .target(
            name: "DynamicDocuments",
            dependencies: ["DynamicRuntime", "DynamicFiles", "DynamicSwiftUI"],
            path: "Contracts/DynamicDocuments"
        ),
        .target(
            name: "RuntimeDocuments",
            dependencies: ["DynamicDocuments", "DynamicFiles", "DynamicRuntime", "RuntimeHost"]
        ),
        .target(
            name: "DynamicText",
            dependencies: ["DynamicRuntime", "DynamicObservation", "DynamicFiles", "DynamicSwiftUI", "DynamicUI"],
            path: "Contracts/DynamicText"
        ),
        .target(
            name: "RuntimeText",
            dependencies: ["DynamicText", "DynamicFiles", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .target(
            name: "DynamicContacts",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicContacts"
        ),
        .target(
            name: "RuntimeContacts",
            dependencies: ["DynamicContacts", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicContactsTests",
            dependencies: ["DynamicContacts", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeContactsTests",
            dependencies: ["RuntimeContacts", "DynamicContacts", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicTransfers",
            dependencies: ["DynamicRuntime", "DynamicFiles", "DynamicObservation"],
            path: "Contracts/DynamicTransfers"
        ),
        .target(
            name: "RuntimeTransfers",
            dependencies: ["DynamicTransfers", "DynamicFiles", "DynamicNetworking", "DynamicRuntime", "RuntimeHost", "RuntimeNetworking"]
        ),
        .testTarget(
            name: "DynamicTransfersTests",
            dependencies: ["DynamicTransfers", "DynamicFiles", "DynamicObservation", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeTransfersTests",
            dependencies: ["RuntimeTransfers", "DynamicTransfers", "DynamicFiles", "RuntimeHost", "RuntimeNative"]
        ),
        .target(
            name: "DynamicPhotos",
            dependencies: ["DynamicRuntime", "DynamicFiles", "DynamicSwiftUI", "DynamicUI"],
            path: "Contracts/DynamicPhotos"
        ),
        .target(
            name: "RuntimePhotos",
            dependencies: ["DynamicPhotos", "DynamicFiles", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicPhotosTests",
            dependencies: ["DynamicPhotos", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimePhotosTests",
            dependencies: ["RuntimePhotos", "DynamicPhotos", "DynamicFiles", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicCamera",
            dependencies: ["DynamicRuntime", "DynamicFiles", "DynamicSwiftUI", "DynamicUI"],
            path: "Contracts/DynamicCamera"
        ),
        .target(
            name: "RuntimeCamera",
            dependencies: ["DynamicCamera", "DynamicFiles", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicCameraTests",
            dependencies: ["DynamicCamera", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeCameraTests",
            dependencies: ["RuntimeCamera", "DynamicCamera", "DynamicFiles", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicCalendar",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicCalendar"
        ),
        .target(
            name: "RuntimeCalendar",
            dependencies: ["DynamicCalendar", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicCalendarTests",
            dependencies: ["DynamicCalendar", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeCalendarTests",
            dependencies: ["RuntimeCalendar", "DynamicCalendar", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicSecrets",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicSecrets"
        ),
        .target(
            name: "RuntimeSecrets",
            dependencies: ["DynamicSecrets", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicSecretsTests",
            dependencies: ["DynamicSecrets", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeSecretsTests",
            dependencies: ["RuntimeSecrets", "DynamicSecrets", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicAuthentication",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicAuthentication"
        ),
        .target(
            name: "RuntimeAuthentication",
            dependencies: ["DynamicAuthentication", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicAuthenticationTests",
            dependencies: ["DynamicAuthentication", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeAuthenticationTests",
            dependencies: ["RuntimeAuthentication", "DynamicAuthentication", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicClipboard",
            dependencies: ["DynamicRuntime", "DynamicFiles"],
            path: "Contracts/DynamicClipboard"
        ),
        .target(
            name: "RuntimeClipboard",
            dependencies: ["DynamicClipboard", "DynamicFiles", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicClipboardTests",
            dependencies: ["DynamicClipboard", "DynamicFiles", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeClipboardTests",
            dependencies: ["RuntimeClipboard", "DynamicClipboard", "DynamicFiles", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicMedia",
            dependencies: ["DynamicRuntime", "DynamicFiles", "DynamicSwiftUI", "DynamicUI"],
            path: "Contracts/DynamicMedia"
        ),
        .target(
            name: "DynamicMapKit",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicUI"],
            path: "Contracts/DynamicMapKit"
        ),
        .target(
            name: "RuntimeMaps",
            dependencies: ["DynamicMapKit", "DynamicRuntime", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicMapKitTests",
            dependencies: ["DynamicMapKit", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeMapsTests",
            dependencies: ["RuntimeMaps", "DynamicMapKit", "RuntimeHost", "RuntimeNative"]
        ),
        .target(
            name: "RuntimeMedia",
            dependencies: ["DynamicMedia", "DynamicFiles", "DynamicRuntime", "RuntimeCore", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicTextTests",
            dependencies: ["DynamicText", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeTextTests",
            dependencies: ["RuntimeText", "DynamicText", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .testTarget(
            name: "DynamicMediaTests",
            dependencies: ["DynamicMedia", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeMediaTests",
            dependencies: ["RuntimeMedia", "DynamicMedia", "DynamicFiles", "RuntimeHost", "RuntimeNative", "RuntimeCore"]
        ),
        .target(
            name: "DynamicBackgroundTasks",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicBackgroundTasks"
        ),
        .target(
            name: "RuntimeBackgroundTasks",
            dependencies: ["DynamicBackgroundTasks", "DynamicFiles", "DynamicRuntime", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicBackgroundTasksTests",
            dependencies: ["DynamicBackgroundTasks", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeBackgroundTasksTests",
            dependencies: ["RuntimeBackgroundTasks", "DynamicBackgroundTasks", "RuntimeHost", "RuntimeNative"]
        ),
        .target(
            name: "DynamicNotifications",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicNotifications"
        ),
        .target(
            name: "RuntimeNotifications",
            dependencies: ["DynamicNotifications", "DynamicRuntime", "RuntimeHost"]
        ),
        .testTarget(
            name: "DynamicNotificationsTests",
            dependencies: ["DynamicNotifications", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeNotificationsTests",
            dependencies: ["RuntimeNotifications", "DynamicNotifications", "RuntimeHost", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicDocumentsTests",
            dependencies: ["DynamicDocuments", "DynamicFiles", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeDocumentsTests",
            dependencies: ["RuntimeDocuments", "DynamicDocuments", "DynamicFiles", "RuntimeHost", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicDefaultsTests",
            dependencies: ["DynamicDefaults", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicFilesTests",
            dependencies: ["DynamicFiles", "RuntimeNative"]
        ),
        .target(
            name: "DynamicGraphics",
            dependencies: ["DynamicRuntime", "CGLES2"],
            path: "Contracts/DynamicGraphics"
        ),
        .testTarget(
            name: "DynamicGraphicsTests",
            dependencies: ["DynamicGraphics", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicFormattingTests",
            dependencies: ["DynamicFormatting", "DynamicObservation", "RuntimeNative"]
        ),
        .target(
            name: "RuntimeFormatting",
            dependencies: ["DynamicFormatting", "DynamicRuntime", "RuntimeHost"]
        ),
        .testTarget(
            name: "RuntimeFormattingTests",
            dependencies: ["RuntimeFormatting", "DynamicFormatting", "RuntimeNative"]
        ),
        .target(
            name: "RuntimeNetworking",
            dependencies: ["DynamicNetworking", "DynamicRuntime", "RuntimeHost", "RuntimeNative"]
        ),
        .testTarget(
            name: "RuntimeNetworkingTests",
            dependencies: ["RuntimeNetworking", "DynamicNetworking", "RuntimeNative"]
        ),

        // MARK: - Linux bundle and sandbox

        .target(
            name: "AppRuntime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CBundleRuntime"
        ),
        .executableTarget(
            name: "BundleRuntime",
            dependencies: ["AppRuntime", "CBundleRuntime"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - Manifest

        // Full Swift, no dependencies: guest.py compiles it with App.swift.
        .target(
            name: "AppManifest"
        ),

        // MARK: - Example

        .target(
            name: "ExampleContracts",
            dependencies: ["DynamicRuntime"],
            path: "examples/ExampleContracts"
        ),
        .target(
            name: "ExampleHost",
            dependencies: ["ExampleContracts", "DynamicRuntime"],
            path: "examples/ExampleHost"
        ),
        .target(
            name: "ExampleApp",
            dependencies: ["ExampleContracts"],
            path: "examples/ExampleApp"
        ),
        .target(
            name: "ExampleUI",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI"],
            path: "examples/ExampleUI"
        ),
        .target(
            name: "ExampleDefaults",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicDefaults"],
            path: "examples/ExampleDefaults"
        ),
        .target(
            name: "ExampleFiles",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles"],
            path: "examples/ExampleFiles"
        ),
        .target(
            name: "ExampleText",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicText"],
            path: "examples/ExampleText"
        ),
        .target(
            name: "ExampleContacts",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicContacts"],
            path: "examples/ExampleContacts"
        ),
        .target(
            name: "ExampleCamera",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicCamera", "DynamicPhotos"],
            path: "examples/ExampleCamera"
        ),
        .target(
            name: "ExamplePhotos",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicPhotos"],
            path: "examples/ExamplePhotos"
        ),
        .target(
            name: "ExampleCalendar",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicCalendar"],
            path: "examples/ExampleCalendar"
        ),
        .target(
            name: "ExampleSignIn",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicSecrets", "DynamicAuthentication"],
            path: "examples/ExampleSignIn"
        ),
        .target(
            name: "ExampleTransfers",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicTransfers"],
            path: "examples/ExampleTransfers"
        ),
        .target(
            name: "ExampleNotes",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI"],
            path: "examples/ExampleNotes"
        ),
        .target(
            name: "ExampleMaps",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicMapKit"],
            path: "examples/ExampleMaps"
        ),
        .target(
            name: "ExampleClipboard",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicClipboard"],
            path: "examples/ExampleClipboard"
        ),
        .target(
            name: "ExampleMedia",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicMedia"],
            path: "examples/ExampleMedia"
        ),
        .target(
            name: "ExampleBackground",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicBackgroundTasks"],
            path: "examples/ExampleBackground"
        ),
        .target(
            name: "ExampleNotifications",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicNotifications"],
            path: "examples/ExampleNotifications"
        ),
        .target(
            name: "ExampleDocuments",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicFiles", "DynamicDocuments"],
            path: "examples/ExampleDocuments"
        ),
        .target(
            name: "ExampleModel",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicCoreModel"],
            path: "examples/ExampleModel"
        ),
        .target(
            name: "ExampleWeb",
            dependencies: ["DynamicRuntime", "DynamicSwiftUI", "DynamicWebKit"],
            path: "examples/ExampleWeb"
        ),
        .target(
            name: "ExampleGL",
            dependencies: ["DynamicRuntime", "DynamicGraphics", "DynamicSwiftUI"],
            path: "examples/ExampleGL"
        ),
        // MARK: - Tests

        .testTarget(
            name: "RuntimeABITests",
            dependencies: ["RuntimeABI"]
        ),
        .testTarget(
            name: "DynamicRuntimeMacrosTests",
            dependencies: [
                "DynamicRuntimeMacros",
                "RuntimeABI",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DynamicObservationTests",
            dependencies: [
                "DynamicObservation",
                "ObservationMacros",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DynamicUITests",
            dependencies: ["DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicSwiftUITests",
            dependencies: ["DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicWebKitTests",
            dependencies: ["DynamicWebKit", "DynamicSwiftUI", "DynamicUI", "RuntimeNative"]
        ),
        .testTarget(
            name: "DynamicCoreModelTests",
            dependencies: [
                "DynamicCoreModel", "RuntimeCoreModel", "DynamicSwiftUI", "DynamicUI", "RuntimeNative",
                .product(name: "CoreModel", package: "CoreModel"),
            ]
        ),
        .testTarget(
            name: "CRuntimeGLTests",
            dependencies: ["CRuntimeGL"]
        ),
        .testTarget(
            name: "RuntimeCoreTests",
            dependencies: ["RuntimeCore"]
        ),
        .testTarget(
            name: "RuntimeHostTests",
            dependencies: ["RuntimeHost", "RuntimeNative", "DynamicFiles", "DynamicDefaults"]
        ),
        .testTarget(
            name: "DynamicRuntimeTests",
            dependencies: [
                "DynamicRuntime",
                "RuntimeNative",
                "ExampleContracts",
                "ExampleHost",
                "ExampleApp",
            ]
        ),
        .testTarget(
            name: "RawStringContractTests",
            dependencies: ["DynamicRuntime", "RuntimeNative"]
        ),
        .testTarget(
            name: "AppRuntimeTests",
            dependencies: ["AppRuntime"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppManifestTests",
            dependencies: ["AppManifest"]
        ),
    ]
)
