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
                .product(name: "WAT", package: "WasmKit"),
            ]
        ),
    ]
)
