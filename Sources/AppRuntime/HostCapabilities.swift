//
//  HostCapabilities.swift
//  AppRuntime
//

/// Execution capabilities of the host system, used for architecture selection.
public struct HostCapabilities: Equatable, Hashable, Codable {

    /// Native architecture of the host.
    public let arch: Arch

    /// Whether the host can execute 32-bit ARM (AArch32 EL0 + armhf loader).
    ///
    /// Gates both native `armv7` execution and box86 (itself an armhf binary)
    /// on arm64 hosts.
    public let supportsAArch32: Bool

    /// Whether the box86 translator (x86 → ARM32) is installed.
    public let hasBox86: Bool

    /// Whether the box64 translator (x86_64 → arm64) is installed.
    public let hasBox64: Bool

    /// Whether 32-bit x86 multilib support is available (x86_64 hosts).
    public let supportsX86Multilib: Bool

    public init(
        arch: Arch,
        supportsAArch32: Bool = false,
        hasBox86: Bool = false,
        hasBox64: Bool = false,
        supportsX86Multilib: Bool = false
    ) {
        self.arch = arch
        self.supportsAArch32 = supportsAArch32
        self.hasBox86 = hasBox86
        self.hasBox64 = hasBox64
        self.supportsX86Multilib = supportsX86Multilib
    }
}

// MARK: - Probing

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

#if canImport(FoundationEssentials) || canImport(Foundation)

public extension HostCapabilities {

    /// Probe the current host's capabilities.
    ///
    /// - Parameter fileExists: File-existence check, injectable for testing.
    ///   Defaults to `FileManager.default.fileExists(atPath:)`.
    static func probe(
        arch: Arch? = .host,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> HostCapabilities? {
        guard let arch = arch else { return nil }
        // AArch32 userland is usable when the armhf dynamic loader is present
        // (implies CONFIG_COMPAT kernel support on a working system).
        let armhfLoaders = [
            "/lib/ld-linux-armhf.so.3",
            "/usr/lib/ld-linux-armhf.so.3"
        ]
        let x86Loaders = [
            "/lib/ld-linux.so.2",
            "/usr/lib/ld-linux.so.2"
        ]
        let box86Paths = ["/usr/bin/box86", "/usr/local/bin/box86"]
        let box64Paths = ["/usr/bin/box64", "/usr/local/bin/box64"]
        return HostCapabilities(
            arch: arch,
            supportsAArch32: arch == .armv7 || (arch == .arm64 && armhfLoaders.contains(where: fileExists)),
            hasBox86: box86Paths.contains(where: fileExists),
            hasBox64: box64Paths.contains(where: fileExists),
            supportsX86Multilib: arch == .x86 || (arch == .x86_64 && x86Loaders.contains(where: fileExists))
        )
    }
}
#endif
