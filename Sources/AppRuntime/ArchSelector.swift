//
//  ArchSelector.swift
//  AppRuntime
//

/// Binary translator used to run a foreign-architecture executable.
public struct Translator: RawRepresentable, Equatable, Hashable, Codable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension Translator {

    /// box86: runs x86 (32-bit) binaries on ARM32/AArch32.
    static var box86: Translator { Translator(rawValue: "box86") }

    /// box64: runs x86_64 binaries on arm64.
    static var box64: Translator { Translator(rawValue: "box64") }
}

extension Translator: CustomStringConvertible {

    public var description: String { rawValue }
}

/// Result of architecture selection: which binary to run and how.
public struct ArchSelection: Equatable, Hashable {

    /// The selected bundle architecture (subdirectory of `bin/`).
    public let arch: Arch

    /// Translator to prepend, or `nil` to exec directly.
    public let translator: Translator?

    public init(arch: Arch, translator: Translator? = nil) {
        self.arch = arch
        self.translator = translator
    }
}

/// Selects the best executable architecture from a bundle for a given host.
public enum ArchSelector {

    public enum Error: Swift.Error, Equatable {
        /// No bundle architecture is runnable on the host.
        case unsupported(bundle: [Arch], host: HostCapabilities)
    }

    /// Candidate ways the host can run code, in preference order.
    static func preferences(for host: HostCapabilities) -> [ArchSelection] {
        switch host.arch {
        case .arm64:
            var candidates = [ArchSelection(arch: .arm64)]
            if host.supportsAArch32 {
                candidates.append(ArchSelection(arch: .armv7))
            }
            if host.hasBox64 {
                candidates.append(ArchSelection(arch: .x86_64, translator: .box64))
            }
            if host.supportsAArch32 && host.hasBox86 {
                candidates.append(ArchSelection(arch: .x86, translator: .box86))
            }
            return candidates
        case .armv7:
            var candidates = [ArchSelection(arch: .armv7)]
            if host.hasBox86 {
                candidates.append(ArchSelection(arch: .x86, translator: .box86))
            }
            return candidates
        case .x86_64:
            var candidates = [ArchSelection(arch: .x86_64)]
            if host.supportsX86Multilib {
                candidates.append(ArchSelection(arch: .x86))
            }
            return candidates
        default:
            return [ArchSelection(arch: host.arch)]
        }
    }

    /// Select the best runnable architecture from `bundle` for `host`.
    ///
    /// - Throws: ``Error/unsupported(bundle:host:)`` if no architecture matches.
    public static func select(
        from bundle: [Arch],
        host: HostCapabilities
    ) throws -> ArchSelection {
        let bundleArches = Set(bundle)
        guard let selection = preferences(for: host).first(where: { bundleArches.contains($0.arch) }) else {
            throw Error.unsupported(bundle: bundle, host: host)
        }
        return selection
    }
}
