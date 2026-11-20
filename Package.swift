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
            dependencies: ["DynamicRuntime"],
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
            dependencies: ["DynamicFormatting", "RuntimeNative"]
        ),
        .target(
            name: "RuntimeFormatting",
            dependencies: ["DynamicFormatting", "DynamicRuntime", "RuntimeHost"]
        ),
        .testTarget(
            name: "RuntimeFormattingTests",
            dependencies: ["RuntimeFormatting", "DynamicFormatting", "RuntimeNative"]
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
