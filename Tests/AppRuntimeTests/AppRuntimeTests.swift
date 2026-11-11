import Testing
import Foundation
@testable import AppRuntime

@Suite struct AppRuntimeTests {

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

    @Test func manifestJSONRoundTrip() throws {
        let manifest = Self.manifest
        let data = try manifest.jsonData()
        let decoded = try Manifest(json: data)
        #expect(decoded == manifest)
        #expect(decoded.formatVersion == Manifest.currentFormatVersion)
        // JSON, not plist: key spot-checks
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "com.example.myapp")
        #expect(json["description"] as? String == "An example app")
        #expect(json["architectures"] as? [String] == ["arm64", "x86_64"])
        #expect(json["formatVersion"] as? Int == 1)
    }

    @Test func manifestDecodingRejectsMalformedJSON() {
        #expect(throws: (any Error).self) { try Manifest(json: Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try Manifest(json: Data("{}".utf8)) }
    }

    @Test func manifestValidation() throws {
        try AppBundle.validate(Self.manifest)
        #expect(throws: (any Error).self) { try AppBundle.validate(copy(Self.manifest, executable: "../evil")) }
        #expect(throws: (any Error).self) { try AppBundle.validate(copy(Self.manifest, executable: "/bin/sh")) }
        #expect(throws: (any Error).self) { try AppBundle.validate(copy(Self.manifest, id: "com/evil")) }
        #expect(throws: (any Error).self) { try AppBundle.validate(copy(Self.manifest, architectures: [])) }
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

    @Test func archFromMachineString() {
        #expect(Arch(machine: "aarch64") == .arm64)
        #expect(Arch(machine: "arm64") == .arm64)
        #expect(Arch(machine: "x86_64") == .x86_64)
        #expect(Arch(machine: "amd64") == .x86_64)
        #expect(Arch(machine: "i686") == .i386)
        #expect(Arch(machine: "armv7l") == .armv7)
        #expect(Arch(machine: "armv6l") == .armv6)
        #expect(Arch(machine: "riscv64") == nil)
    }

    @Test func archHost() {
        // On any supported dev/CI machine the host arch should be recognized.
        #expect(Arch.host != nil)
    }

    // MARK: - ArchSelector truth table

    @Test func arm64HostPrefersNative() throws {
        let host = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64, .armv7, .arm64], host: host)
        #expect(selection == ArchSelection(arch: .arm64))
    }

    @Test func arm64HostFallsBackToArmv7OnlyWithAArch32() throws {
        let bundle: [Arch] = [.armv7]
        let with = HostCapabilities(arch: .arm64, supportsAArch32: true)
        #expect(try ArchSelector.select(from: bundle, host: with) == ArchSelection(arch: .armv7))
        let without = HostCapabilities(arch: .arm64, supportsAArch32: false)
        #expect(throws: (any Error).self) { try ArchSelector.select(from: bundle, host: without) }
    }

    @Test func arm64HostRunsX86_64ViaBox64() throws {
        let host = HostCapabilities(arch: .arm64, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64], host: host)
        #expect(selection == ArchSelection(arch: .x86_64, translator: .box64))
    }

    @Test func arm64HostRunsX86ViaBox86RequiresAArch32() throws {
        let bundle: [Arch] = [.i386]
        let capable = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true)
        #expect(try ArchSelector.select(from: bundle, host: capable) == ArchSelection(arch: .i386, translator: .box86))
        // box86 present but no AArch32 (64-bit-only core): unrunnable.
        let unable = HostCapabilities(arch: .arm64, supportsAArch32: false, hasBox86: true)
        #expect(throws: (any Error).self) { try ArchSelector.select(from: bundle, host: unable) }
    }

    @Test func arm64HostPrefersBox64OverBox86() throws {
        let host = HostCapabilities(arch: .arm64, supportsAArch32: true, hasBox86: true, hasBox64: true)
        let selection = try ArchSelector.select(from: [.i386, .x86_64], host: host)
        #expect(selection == ArchSelection(arch: .x86_64, translator: .box64))
    }

    @Test func armv7Host() throws {
        let host = HostCapabilities(arch: .armv7, supportsAArch32: true, hasBox86: true)
        #expect(try ArchSelector.select(from: [.armv7, .i386], host: host) == ArchSelection(arch: .armv7))
        #expect(try ArchSelector.select(from: [.i386], host: host) == ArchSelection(arch: .i386, translator: .box86))
        #expect(throws: (any Error).self) { try ArchSelector.select(from: [.arm64], host: host) }
    }

    @Test func x86_64Host() throws {
        let multilib = HostCapabilities(arch: .x86_64, supportsX86Multilib: true)
        #expect(try ArchSelector.select(from: [.x86_64], host: multilib) == ArchSelection(arch: .x86_64))
        #expect(try ArchSelector.select(from: [.i386], host: multilib) == ArchSelection(arch: .i386))
        let pure64 = HostCapabilities(arch: .x86_64)
        #expect(throws: (any Error).self) { try ArchSelector.select(from: [.i386], host: pure64) }
        #expect(throws: (any Error).self) { try ArchSelector.select(from: [.arm64, .armv7], host: pure64) }
    }

    @Test func unsupportedError() {
        let host = HostCapabilities(arch: .arm64)
        #expect(throws: ArchSelector.Error.unsupported(bundle: [.i386], host: host)) {
            try ArchSelector.select(from: [.i386], host: host)
        }
    }

    // MARK: - AppBundle fixture

    @Test func appBundleLoadAndPathResolution() throws {
        let root = try makeFixtureBundle(architectures: [.arm64, .x86_64], withLib: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let bundle = try AppBundle(path: root)
        #expect(bundle.manifest.id == "com.example.myapp")
        #expect(bundle.executablePath(for: .arm64) == root + "/bin/arm64/myapp")
        #expect(bundle.libraryPath(for: .arm64) == root + "/lib/arm64")
        #expect(bundle.libraryPath(for: .x86_64) == nil)

        #expect(bundle.workingDirectory == root)

        // arm64 host: native binary, no translator.
        let native = try bundle.selectExecutable(for: HostCapabilities(arch: .arm64))
        #expect(native.selection == ArchSelection(arch: .arm64))
        #expect(native.executable == root + "/bin/arm64/myapp")

        // armv7 host: nothing runnable.
        #expect(throws: (any Error).self) { try bundle.selectExecutable(for: HostCapabilities(arch: .armv7)) }
    }

    @Test func appBundleRejectsMissingManifest() throws {
        let root = NSTemporaryDirectory() + "empty-" + UUID().uuidString + ".app"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let error = #expect(throws: AppBundle.Error.self) { try AppBundle(path: root) }
        guard case .missingManifest? = error else {
            Issue.record("Expected missingManifest, got \(String(describing: error))")
            return
        }
    }

    @Test func appBundleRejectsMissingBinary() throws {
        // Declares x86 but ships no bin/i386/myapp.
        let root = try makeFixtureBundle(architectures: [.arm64], manifestArchitectures: [.arm64, .i386])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let error = #expect(throws: AppBundle.Error.self) { try AppBundle(path: root) }
        guard case .missingBinary(let arch, _)? = error else {
            Issue.record("Expected missingBinary, got \(String(describing: error))")
            return
        }
        #expect(arch == .i386)
    }

    @Test func appBundleResourceLookup() throws {
        let root = try makeFixtureBundle(architectures: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileManager = FileManager.default

        // No resources/ directory yet.
        var bundle = try AppBundle(path: root)
        #expect(bundle.resourcePath == nil)
        #expect(bundle.iconPath == nil)
        #expect(bundle.path(forResource: "logo", ofType: "png") == nil)

        // Populate resources/ and icon.png.
        try fileManager.createDirectory(atPath: root + "/resources/images", withIntermediateDirectories: true)
        fileManager.createFile(atPath: root + "/resources/logo.png", contents: Data())
        fileManager.createFile(atPath: root + "/resources/images/bg.jpg", contents: Data())
        fileManager.createFile(atPath: root + "/icon.png", contents: Data())
        bundle = try AppBundle(path: root)

        #expect(bundle.resourcePath == root + "/resources")
        #expect(bundle.resourceURL?.path == root + "/resources")
        #expect(bundle.iconPath == root + "/icon.png")
        #expect(bundle.path(forResource: "logo", ofType: "png") == root + "/resources/logo.png")
        #expect(bundle.path(forResource: "logo.png") == root + "/resources/logo.png")
        #expect(bundle.path(forResource: "images/bg", ofType: "jpg") == root + "/resources/images/bg.jpg")
        #expect(bundle.url(forResource: "logo", withExtension: "png")?.lastPathComponent == "logo.png")
        #expect(bundle.path(forResource: "missing", ofType: "png") == nil)
        // Traversal outside resources/ is rejected.
        #expect(bundle.path(forResource: "../manifest", ofType: "json") == nil)
    }

    @Test func appBundleTrimsTrailingSlash() throws {
        let root = try makeFixtureBundle(architectures: [.arm64])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bundle = try AppBundle(path: root + "/")
        #expect(bundle.path == root)
        #expect(bundle.executablePath(for: .arm64) == root + "/bin/arm64/myapp")
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

    @Test func hostCapabilitiesProbeInjection() throws {
        // Simulated arm64 board with armhf loader and box64 only.
        let present: Set<String> = ["/lib/ld-linux-armhf.so.3", "/usr/bin/box64"]
        let host = try #require(HostCapabilities.probe(arch: .arm64, fileExists: { present.contains($0) }))
        #expect(host.arch == .arm64)
        #expect(host.supportsAArch32)
        #expect(!host.hasBox86)
        #expect(host.hasBox64)
        #expect(!host.supportsX86Multilib)

        // 64-bit-only core, no translators.
        let bare = try #require(HostCapabilities.probe(arch: .arm64, fileExists: { _ in false }))
        #expect(!bare.supportsAArch32)
        #expect(!bare.hasBox64)

        #expect(HostCapabilities.probe(arch: nil, fileExists: { _ in true }) == nil)
    }
}
