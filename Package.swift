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
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        // Shared: C ABI, wire model, guest library and macros.
        .library(name: "CRuntime", targets: ["CRuntime"]),
        .library(name: "RuntimeABI", targets: ["RuntimeABI"]),
        .library(name: "DynamicRuntime", targets: ["DynamicRuntime"]),
        // Shared: runtime core with the Swift-registry backend.
        .library(name: "RuntimeCore", targets: ["RuntimeCore"]),
        .library(name: "RuntimeNative", targets: ["RuntimeNative"]),
        // Shared: portable provider contracts (declarations; hosts implement them).
        .library(name: "DynamicBluetooth", targets: ["DynamicBluetooth"]),
        .library(name: "DynamicLocation", targets: ["DynamicLocation"]),
        .library(name: "DynamicMotion", targets: ["DynamicMotion"]),
        .library(name: "DynamicNetworking", targets: ["DynamicNetworking"]),
        .library(name: "DynamicFormatting", targets: ["DynamicFormatting"]),
        // Wasm: WasmKit import shim.
        .library(name: "RuntimeWasm", targets: ["RuntimeWasm"]),
        // Linux: bundle model and sandboxing launcher.
        .library(name: "AppRuntime", targets: ["AppRuntime"]),
        .executable(name: "bundle-runtime", targets: ["BundleRuntime"]),
        // Example guest app. Scripts/guest.py builds its slices and bundle.
        .library(name: "ExampleApp", type: .static, targets: ["ExampleApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0"..<"605.0.0"),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", from: "0.4.2"),
        .package(url: "https://github.com/PureSwift/Bluetooth.git", from: "8.2.1"),
    ],
    targets: [

        // MARK: - Shared (Embedded Swift compatible)

        .target(
            name: "CRuntime"
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

        // MARK: - Contracts

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
        .target(
            name: "DynamicFormatting",
            dependencies: ["DynamicRuntime"],
            path: "Contracts/DynamicFormatting"
        ),
        .testTarget(
            name: "DynamicFormattingTests",
            dependencies: ["DynamicFormatting", "RuntimeNative"]
        ),

        // MARK: - Wasm

        .target(
            name: "RuntimeWasm",
            dependencies: [
                "RuntimeCore",
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
            ]
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
            name: "RuntimeCoreTests",
            dependencies: ["RuntimeCore"]
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
            name: "RuntimeWasmTests",
            dependencies: [
                "RuntimeWasm",
                "RuntimeNative",
                "ExampleHost",
                .product(name: "WAT", package: "WasmKit"),
            ]
        ),
        .testTarget(
            name: "AppRuntimeTests",
            dependencies: ["AppRuntime"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
