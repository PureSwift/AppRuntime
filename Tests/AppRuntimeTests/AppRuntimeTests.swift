import XCTest
import Foundation
@testable import AppRuntime

final class AppRuntimeTests: XCTestCase {

    // MARK: - Manifest

    static let manifest = Manifest(
        id: "com.example.myapp",
        name: "My App",
        appDescription: "An example app",
        sdk: "1.0",
        executable: "myapp",
        version: "1.2.3",
        build: "42",
        copyright: "© 2026 Example",
        capabilities: ["Display", "Audio"],
        architectures: [.arm64, .x86_64]
    )

    func testManifestJSONRoundTrip() throws {
        let manifest = Self.manifest
        let data = try manifest.jsonData()
        let decoded = try Manifest(json: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.formatVersion, Manifest.currentFormatVersion)
        // JSON, not plist: key spot-checks
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "com.example.myapp")
        XCTAssertEqual(json["description"] as? String, "An example app")
        XCTAssertEqual(json["architectures"] as? [String], ["arm64", "x86_64"])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
    }

    func testManifestDecodingRejectsMalformedJSON() {
        XCTAssertThrowsError(try Manifest(json: Data("not json".utf8)))
        XCTAssertThrowsError(try Manifest(json: Data("{}".utf8)))
    }

    func testManifestValidation() throws {
        try AppBundle.validate(Self.manifest)
        XCTAssertThrowsError(try AppBundle.validate(copy(Self.manifest, executable: "../evil")))
        XCTAssertThrowsError(try AppBundle.validate(copy(Self.manifest, executable: "/bin/sh")))
        XCTAssertThrowsError(try AppBundle.validate(copy(Self.manifest, id: "com/evil")))
        XCTAssertThrowsError(try AppBundle.validate(copy(Self.manifest, architectures: [])))
    }

    private func copy(
        _ manifest: Manifest,
        id: String? = nil,
        executable: String? = nil,
        architectures: [Arch]? = nil
    ) -> Manifest {
        Manifest(
            formatVersion: manifest.formatVersion,
            id: id ?? manifest.id,
            name: manifest.name,
            appDescription: manifest.appDescription,
            sdk: manifest.sdk,
            executable: executable ?? manifest.executable,
            version: manifest.version,
            build: manifest.build,
            copyright: manifest.copyright,
            capabilities: manifest.capabilities,
            architectures: architectures ?? manifest.architectures
        )
    }

    // MARK: - Arch

    func testArchFromMachineString() {
        XCTAssertEqual(Arch(machine: "aarch64"), .arm64)
        XCTAssertEqual(Arch(machine: "arm64"), .arm64)
        XCTAssertEqual(Arch(machine: "x86_64"), .x86_64)
        XCTAssertEqual(Arch(machine: "amd64"), .x86_64)
        XCTAssertEqual(Arch(machine: "i686"), .i386)
        XCTAssertEqual(Arch(machine: "armv7l"), .armv7)
        XCTAssertEqual(Arch(machine: "armv6l"), .armv6)
        XCTAssertNil(Arch(machine: "riscv64"))
    }

    func testArchHost() {
        // On any supported dev/CI machine the host arch should be recognized.
        XCTAssertNotNil(Arch.host)
    }

    // MARK: - ArchSelector truth table

    func testArm64HostPrefersNative() throws {
        let host = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64, .armv7, .arm64], host: host)
        XCTAssertEqual(selection, ArchSelection(arch: .arm64))
    }

    func testArm64HostFallsBackToArmv7OnlyWithAArch32() throws {
        let bundle: [Arch] = [.armv7]
        let with = HostCapabilities(arch: .arm64, supportsAArch32: true)
        XCTAssertEqual(try ArchSelector.select(from: bundle, host: with), ArchSelection(arch: .armv7))
        let without = HostCapabilities(arch: .arm64, supportsAArch32: false)
        XCTAssertThrowsError(try ArchSelector.select(from: bundle, host: without))
    }

    func testArm64HostRunsX86_64ViaBox64() throws {
        let host = HostCapabilities(arch: .arm64, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64], host: host)
        XCTAssertEqual(selection, ArchSelection(arch: .x86_64, translator: .box64))
    }

    func testArm64HostRunsX86ViaBox86RequiresAArch32() throws {
        let bundle: [Arch] = [.i386]
        let capable = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true)
        XCTAssertEqual(
            try ArchSelector.select(from: bundle, host: capable),
            ArchSelection(arch: .i386, translator: .box86)
        )
        // box86 present but no AArch32 (64-bit-only core): unrunnable.
        let unable = HostCapabilities(arch: .arm64, supportsAArch32: false, hasBox86: true)
        XCTAssertThrowsError(try ArchSelector.select(from: bundle, host: unable))
    }

    func testArm64HostPrefersBox64OverBox86() throws {
        let host = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64], host: host)
        XCTAssertEqual(selection, ArchSelection(arch: .x86_64, translator: .box64))
    }

    func testArmv7Host() throws {
        let host = HostCapabilities(arch: .armv7, supportsAArch32: true, hasBox86: true)
        XCTAssertEqual(try ArchSelector.select(from: [.armv7, .i386], host: host), ArchSelection(arch: .armv7))
        XCTAssertEqual(
            try ArchSelector.select(from: [.i386], host: host),
            ArchSelection(arch: .i386, translator: .box86)
        )
        XCTAssertThrowsError(try ArchSelector.select(from: [.arm64], host: host))
    }

    func testX86_64Host() throws {
        let multilib = HostCapabilities(arch: .x86_64, supportsX86Multilib: true)
        XCTAssertEqual(try ArchSelector.select(from: [.x86_64], host: multilib), ArchSelection(arch: .x86_64))
        XCTAssertEqual(try ArchSelector.select(from: [.i386], host: multilib), ArchSelection(arch: .i386))
        let pure64 = HostCapabilities(arch: .x86_64)
        XCTAssertThrowsError(try ArchSelector.select(from: [.i386], host: pure64))
        XCTAssertThrowsError(try ArchSelector.select(from: [.arm64, .armv7], host: pure64))
    }

    func testUnsupportedError() {
        let host = HostCapabilities(arch: .arm64)
        XCTAssertThrowsError(try ArchSelector.select(from: [.i386], host: host)) { error in
            XCTAssertEqual(error as? ArchSelector.Error, .unsupported(bundle: [.i386], host: host))
        }
    }

    // MARK: - AppBundle fixture

    func testAppBundleLoadAndPathResolution() throws {
        let root = try makeFixtureBundle(architectures: [.arm64, .x86_64], withLib: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let bundle = try AppBundle(path: root)
        XCTAssertEqual(bundle.manifest.id, "com.example.myapp")
        XCTAssertEqual(bundle.executablePath(for: .arm64), root + "/bin/arm64/myapp")
        XCTAssertEqual(bundle.libraryPath(for: .arm64), root + "/lib/arm64")
        XCTAssertNil(bundle.libraryPath(for: .x86_64))

        XCTAssertEqual(bundle.workingDirectory, root)

        // arm64 host: native binary, no translator.
        let native = try bundle.selectExecutable(for: HostCapabilities(arch: .arm64))
        XCTAssertEqual(native.selection, ArchSelection(arch: .arm64))
        XCTAssertEqual(native.executable, root + "/bin/arm64/myapp")

        // armv7 host: nothing runnable.
        XCTAssertThrowsError(try bundle.selectExecutable(for: HostCapabilities(arch: .armv7)))
    }

    func testAppBundleRejectsMissingManifest() throws {
        let root = NSTemporaryDirectory() + "empty-" + UUID().uuidString + ".app"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try AppBundle(path: root)) { error in
            guard case AppBundle.Error.missingManifest = error else {
                return XCTFail("Expected missingManifest, got \(error)")
            }
        }
    }

    func testAppBundleRejectsMissingBinary() throws {
        // Declares x86 but ships no bin/i386/myapp.
        let root = try makeFixtureBundle(architectures: [.arm64], manifestArchitectures: [.arm64, .i386])
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try AppBundle(path: root)) { error in
            guard case AppBundle.Error.missingBinary(let arch, _) = error else {
                return XCTFail("Expected missingBinary, got \(error)")
            }
            XCTAssertEqual(arch, .i386)
        }
    }

    func testAppBundleResourceLookup() throws {
        let root = try makeFixtureBundle(architectures: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileManager = FileManager.default

        // No resources/ directory yet.
        var bundle = try AppBundle(path: root)
        XCTAssertNil(bundle.resourcePath)
        XCTAssertNil(bundle.iconPath)
        XCTAssertNil(bundle.path(forResource: "logo", ofType: "png"))

        // Populate resources/ and icon.png.
        try fileManager.createDirectory(atPath: root + "/resources/images", withIntermediateDirectories: true)
        fileManager.createFile(atPath: root + "/resources/logo.png", contents: Data())
        fileManager.createFile(atPath: root + "/resources/images/bg.jpg", contents: Data())
        fileManager.createFile(atPath: root + "/icon.png", contents: Data())
        bundle = try AppBundle(path: root)

        XCTAssertEqual(bundle.resourcePath, root + "/resources")
        XCTAssertEqual(bundle.resourceURL?.path, root + "/resources")
        XCTAssertEqual(bundle.iconPath, root + "/icon.png")
        XCTAssertEqual(bundle.path(forResource: "logo", ofType: "png"), root + "/resources/logo.png")
        XCTAssertEqual(bundle.path(forResource: "logo.png"), root + "/resources/logo.png")
        XCTAssertEqual(bundle.path(forResource: "images/bg", ofType: "jpg"), root + "/resources/images/bg.jpg")
        XCTAssertEqual(bundle.url(forResource: "logo", withExtension: "png")?.lastPathComponent, "logo.png")
        XCTAssertNil(bundle.path(forResource: "missing", ofType: "png"))
        // Traversal outside resources/ is rejected.
        XCTAssertNil(bundle.path(forResource: "../manifest", ofType: "json"))
    }

    func testAppBundleTrimsTrailingSlash() throws {
        let root = try makeFixtureBundle(architectures: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bundle = try AppBundle(path: root + "/")
        XCTAssertEqual(bundle.path, root)
        XCTAssertEqual(bundle.executablePath(for: .arm64), root + "/bin/arm64/myapp")
    }

    private func makeFixtureBundle(
        architectures: [Arch],
        manifestArchitectures: [Arch]? = nil,
        withLib: [Arch] = []
    ) throws -> String {
        let fileManager = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).standardizingPath
            + "/com.example.myapp-" + UUID().uuidString + ".app"
        let manifest = copy(Self.manifest, architectures: manifestArchitectures ?? architectures)
        for arch in architectures {
            let binDir = root + "/bin/" + arch.rawValue
            try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            fileManager.createFile(atPath: binDir + "/myapp", contents: Data("#!/bin/sh\n".utf8))
        }
        for arch in withLib {
            try fileManager.createDirectory(atPath: root + "/lib/" + arch.rawValue, withIntermediateDirectories: true)
        }
        try manifest.jsonData().write(to: URL(fileURLWithPath: root + "/" + Manifest.fileName))
        return root
    }

    // MARK: - HostCapabilities probe

    func testHostCapabilitiesProbeInjection() throws {
        // Simulated arm64 board with armhf loader and box64 only.
        let present: Set<String> = ["/lib/ld-linux-armhf.so.3", "/usr/bin/box64"]
        let host = try XCTUnwrap(HostCapabilities.probe(arch: .arm64, fileExists: { present.contains($0) }))
        XCTAssertEqual(host.arch, .arm64)
        XCTAssertTrue(host.supportsAArch32)
        XCTAssertFalse(host.hasBox86)
        XCTAssertTrue(host.hasBox64)
        XCTAssertFalse(host.supportsX86Multilib)

        // 64-bit-only core, no translators.
        let bare = try XCTUnwrap(HostCapabilities.probe(arch: .arm64, fileExists: { _ in false }))
        XCTAssertFalse(bare.supportsAArch32)
        XCTAssertFalse(bare.hasBox64)

        XCTAssertNil(HostCapabilities.probe(arch: nil, fileExists: { _ in true }))
    }
}
