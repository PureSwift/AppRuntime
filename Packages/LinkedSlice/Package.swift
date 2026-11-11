// swift-tools-version:6.4
import Foundation
import PackageDescription

/// A host built the way a platform host is: AppRuntime without the
/// `GuestExports` trait, linked with an app's library.
///
/// The environment picks the library; each test run links one, since every
/// library defines `rt_main`, `rt_dispatch` and `rt_finalize`:
///
/// - `APPRUNTIME_LINKED_PRODUCT`: `ExampleApp` (the default) or `ExampleUI`.
/// - `APPRUNTIME_LINKED_ENGINE`:
///   - `slice` (the default): the sealed macOS slice, from
///     `Scripts/guest.py slice --product <product> --target macos`;
///   - `wasm2c`: `App.wasm` translated to C, from `Scripts/build-wasm.sh
///     <product>` and `Scripts/wasm2c-shim.py build --wasm
///     .build/guest/<product>/wasm32/App.wasm --output
///     .build/guest/<product>/wasm2c`.
///
/// Without the library, the test target builds without it, and its tests are
/// skipped.
let environment = ProcessInfo.processInfo.environment
let product = environment["APPRUNTIME_LINKED_PRODUCT"] ?? "ExampleApp"
let engine = environment["APPRUNTIME_LINKED_ENGINE"] ?? "slice"
let library = URL(fileURLWithPath: Context.packageDirectory)
    .appendingPathComponent("../../.build/guest/\(product)/\(engine == "wasm2c" ? "wasm2c" : "macos")/libapp.a")
    .standardizedFileURL.path
let linked = FileManager.default.fileExists(atPath: library)

let package = Package(
    name: "LinkedSlice",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(name: "AppRuntime", path: "../..", traits: []),
    ],
    targets: [
        .testTarget(
            name: "LinkedSliceTests",
            dependencies: [
                .product(name: "CRuntime", package: "AppRuntime"),
                .product(name: "DynamicRuntime", package: "AppRuntime"),
                .product(name: "DynamicUI", package: "AppRuntime"),
                .product(name: "RuntimeABI", package: "AppRuntime"),
                .product(name: "RuntimeCore", package: "AppRuntime"),
                .product(name: "RuntimeNative", package: "AppRuntime"),
                .product(name: "ExampleContracts", package: "AppRuntime"),
                .product(name: "ExampleHost", package: "AppRuntime"),
            ],
            swiftSettings: linked ? [.define("LINKED_SLICE"), .define("LINKED_\(product.uppercased())")] : [],
            linkerSettings: linked ? [.unsafeFlags([library])] : []
        ),
    ]
)
