// swift-tools-version:6.4
import PackageDescription

/// The WasmKit engine: runs a guest's `App.wasm` in the WasmKit interpreter.
///
/// It's a package of its own because WasmKit needs macOS 15 / iOS 18, and
/// SwiftPM rejects a dependency whose minimum is higher than its client's.
/// AppRuntime itself supports macOS 12 / iOS 15, so hosts that ship only
/// native slices and wasm2c don't depend on WasmKit.
let package = Package(
    name: "RuntimeWasm",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "RuntimeWasm", targets: ["RuntimeWasm"]),
    ],
    dependencies: [
        .package(name: "AppRuntime", path: "../.."),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", from: "0.4.2"),
    ],
    targets: [
        .target(
            name: "RuntimeWasm",
            dependencies: [
                .product(name: "RuntimeABI", package: "AppRuntime"),
                .product(name: "RuntimeCore", package: "AppRuntime"),
                .product(name: "CRuntimeGL", package: "AppRuntime"),
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
            ]
        ),
        .testTarget(
            name: "RuntimeWasmTests",
            dependencies: [
                "RuntimeWasm",
                .product(name: "RuntimeABI", package: "AppRuntime"),
                .product(name: "RuntimeNative", package: "AppRuntime"),
                .product(name: "ExampleHost", package: "AppRuntime"),
                .product(name: "DynamicUI", package: "AppRuntime"),
                .product(name: "DynamicGraphics", package: "AppRuntime"),
                .product(name: "DynamicWebKit", package: "AppRuntime"),
                .product(name: "DynamicFiles", package: "AppRuntime"),
                .product(name: "DynamicDocuments", package: "AppRuntime"),
                .product(name: "RuntimeDocuments", package: "AppRuntime"),
                .product(name: "DynamicNotifications", package: "AppRuntime"),
                .product(name: "RuntimeNotifications", package: "AppRuntime"),
                .product(name: "DynamicBackgroundTasks", package: "AppRuntime"),
                .product(name: "RuntimeBackgroundTasks", package: "AppRuntime"),
                .product(name: "DynamicText", package: "AppRuntime"),
                .product(name: "RuntimeText", package: "AppRuntime"),
                .product(name: "DynamicClipboard", package: "AppRuntime"),
                .product(name: "DynamicTransfers", package: "AppRuntime"),
                .product(name: "RuntimeTransfers", package: "AppRuntime"),
                .product(name: "RuntimeClipboard", package: "AppRuntime"),
                .product(name: "DynamicSecrets", package: "AppRuntime"),
                .product(name: "RuntimeSecrets", package: "AppRuntime"),
                .product(name: "DynamicAuthentication", package: "AppRuntime"),
                .product(name: "RuntimeAuthentication", package: "AppRuntime"),
                .product(name: "DynamicCalendar", package: "AppRuntime"),
                .product(name: "RuntimeCalendar", package: "AppRuntime"),
                .product(name: "DynamicContacts", package: "AppRuntime"),
                .product(name: "RuntimeContacts", package: "AppRuntime"),
                .product(name: "DynamicPhotos", package: "AppRuntime"),
                .product(name: "RuntimePhotos", package: "AppRuntime"),
                .product(name: "DynamicCamera", package: "AppRuntime"),
                .product(name: "RuntimeCamera", package: "AppRuntime"),
                .product(name: "DynamicMedia", package: "AppRuntime"),
                .product(name: "RuntimeMedia", package: "AppRuntime"),
                .product(name: "DynamicMapKit", package: "AppRuntime"),
                .product(name: "RuntimeMaps", package: "AppRuntime"),
                .product(name: "DynamicDrawing", package: "AppRuntime"),
                .product(name: "RuntimeDrawing", package: "AppRuntime"),
                .product(name: "DynamicDefaults", package: "AppRuntime"),
                .product(name: "DynamicCoreModel", package: "AppRuntime"),
                .product(name: "RuntimeCoreModel", package: "AppRuntime"),
                .product(name: "RuntimeHost", package: "AppRuntime"),
                .product(name: "CGLES2", package: "AppRuntime"),
                .product(name: "CRuntimeGL", package: "AppRuntime"),
                .product(name: "WAT", package: "WasmKit"),
            ]
        ),
    ]
)
