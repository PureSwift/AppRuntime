// swift-tools-version:6.4
import Foundation
import PackageDescription

/// A host built the way a platform host is: AppRuntime without the
/// `GuestExports` trait, linked with an app's sealed native slice.
///
/// The slice is `ExampleApp`'s for macOS, built by
/// `Scripts/guest.py slice --product ExampleApp --target macos`. Without it
/// the test target builds without the slice, and its tests are skipped.
let slice = URL(fileURLWithPath: Context.packageDirectory)
    .appendingPathComponent("../../.build/guest/ExampleApp/macos/libapp.a")
    .standardizedFileURL.path
let hasSlice = FileManager.default.fileExists(atPath: slice)

let package = Package(
    name: "LinkedSlice",
    platforms: [
        .macOS(.v15),
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
                .product(name: "RuntimeABI", package: "AppRuntime"),
                .product(name: "RuntimeCore", package: "AppRuntime"),
                .product(name: "RuntimeNative", package: "AppRuntime"),
                .product(name: "ExampleContracts", package: "AppRuntime"),
                .product(name: "ExampleHost", package: "AppRuntime"),
            ],
            swiftSettings: hasSlice ? [.define("LINKED_SLICE")] : [],
            linkerSettings: hasSlice ? [.unsafeFlags([slice])] : []
        ),
    ]
)
