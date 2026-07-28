// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppRuntime",
    products: [
        .library(
            name: "AppRuntime",
            targets: ["AppRuntime"]),
        .executable(
            name: "bundle-runtime",
            targets: ["BundleRuntime"]),
    ],
    targets: [
        .target(
            name: "AppRuntime",
            dependencies: []),
        .target(
            name: "CBundleRuntime"),
        .executableTarget(
            name: "BundleRuntime",
            dependencies: ["AppRuntime", "CBundleRuntime"]),
        .testTarget(
            name: "AppRuntimeTests",
            dependencies: ["AppRuntime"]),
    ]
)
