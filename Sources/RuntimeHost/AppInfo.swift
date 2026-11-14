#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import RuntimeABI

/// The app's keys, from the universal bundle's `Info.plist` (or the copy a
/// packager made of them): what the app was built against and what it uses.
///
/// Every host reads the same keys:
///
/// | Key | |
/// |---|---|
/// | `RTABIVersion` | the rt ABI the app was built against; required |
/// | `RTContracts` | `Name`, `Version` and `Kind` of each contract it uses |
/// | `RTCapabilities` | the capabilities it declares |
/// | `RTCapabilityUsage` | each capability's usage-text key |
/// | `RTTargets` | the slices it was built for |
public struct AppInfo: Equatable, Sendable {

    /// A contract the app uses, from `RTContracts`.
    public struct Contract: Equatable, Hashable, Sendable {

        public var name: String

        public var version: UInt32

        public var kind: ContractKind

        public init(name: String, version: UInt32, kind: ContractKind) {
            self.name = name
            self.version = version
            self.kind = kind
        }
    }

    /// `CFBundleIdentifier`.
    public var identifier: String

    /// `CFBundleName`, or the identifier's last part.
    public var name: String

    /// `CFBundleShortVersionString`.
    public var version: String

    /// `CFBundleVersion`.
    public var build: String

    public var abiVersion: UInt32

    public var targets: [String]

    public var capabilities: Set<Capability>

    public var contracts: [Contract]

    /// `RTCapabilityUsage`: each capability's usage-text key.
    public var capabilityUsage: [String: String]

    public init(
        identifier: String,
        name: String? = nil,
        version: String = "",
        build: String = "",
        abiVersion: UInt32,
        targets: [String] = [],
        capabilities: Set<Capability> = [],
        contracts: [Contract] = [],
        capabilityUsage: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.name = name ?? identifier.split(separator: ".").last.map(String.init) ?? identifier
        self.version = version
        self.build = build
        self.abiVersion = abiVersion
        self.targets = targets
        self.capabilities = capabilities
        self.contracts = contracts
        self.capabilityUsage = capabilityUsage
    }

    /// The names of the contracts the app uses.
    public var contractNames: Set<String> {
        Set(contracts.map(\.name))
    }
}

// MARK: Reading

extension AppInfo {

    /// Reads the keys from an `Info.plist` dictionary, such as
    /// `Bundle.main.infoDictionary`.
    public init(infoDictionary info: [String: Any]) throws(AppInfoError) {
        guard let abiVersion = Self.uint32(info[Keys.CodingKeys.abiVersion.rawValue]) else {
            throw .missing(Keys.CodingKeys.abiVersion.rawValue)
        }
        var contracts = [Contract]()
        for entry in info[Keys.CodingKeys.contracts.rawValue] as? [[String: Any]] ?? [] {
            guard let name = entry["Name"] as? String,
                  let version = Self.uint32(entry["Version"]),
                  let kind = (entry["Kind"] as? String).flatMap(ContractKind.init(name:)) else {
                throw .malformed(Keys.CodingKeys.contracts.rawValue)
            }
            contracts.append(Contract(name: name, version: version, kind: kind))
        }
        self.init(
            identifier: info["CFBundleIdentifier"] as? String ?? "",
            name: info["CFBundleName"] as? String,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            abiVersion: abiVersion,
            targets: info["RTTargets"] as? [String] ?? [],
            capabilities: Set((info["RTCapabilities"] as? [String] ?? []).map(Capability.init(_:))),
            contracts: contracts,
            capabilityUsage: info["RTCapabilityUsage"] as? [String: String] ?? [:]
        )
    }

    /// Reads the keys from a property list's bytes, XML or binary. Uses
    /// `PropertyListDecoder`, so hosts that link only `FoundationEssentials`
    /// can read it.
    public init(propertyList data: Data) throws(AppInfoError) {
        let keys: Keys
        do {
            keys = try PropertyListDecoder().decode(Keys.self, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.dataCorrupted(context) {
            throw .malformed(context.codingPath.first?.stringValue ?? "Info.plist")
        } catch let DecodingError.keyNotFound(key, context) {
            throw .malformed(context.codingPath.first?.stringValue ?? key.stringValue)
        } catch {
            throw .malformed("Info.plist")
        }
        guard let abiVersion = keys.abiVersion else {
            throw .missing(Keys.CodingKeys.abiVersion.rawValue)
        }
        var contracts = [Contract]()
        for entry in keys.contracts ?? [] {
            guard let kind = ContractKind(name: entry.kind) else {
                throw .malformed(Keys.CodingKeys.contracts.rawValue)
            }
            contracts.append(Contract(name: entry.name, version: entry.version, kind: kind))
        }
        self.init(
            identifier: keys.identifier ?? "",
            name: keys.name,
            version: keys.version ?? "",
            build: keys.build ?? "",
            abiVersion: abiVersion,
            targets: keys.targets ?? [],
            capabilities: Set((keys.capabilities ?? []).map(Capability.init(_:))),
            contracts: contracts,
            capabilityUsage: keys.capabilityUsage ?? [:]
        )
    }

    /// Reads a property list file: a universal bundle's `Info.plist`.
    public init(contentsOf path: String) throws(AppInfoError) {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw .missing(path)
        }
        try self.init(propertyList: data)
    }

    /// An integer key, as `PropertyListSerialization` or a bridged
    /// dictionary has it.
    private static func uint32(_ value: Any?) -> UInt32? {
        switch value {
        case let value as UInt32: value
        case let value as Int: UInt32(exactly: value)
        case let value as Int64: UInt32(exactly: value)
        case let value as UInt64: UInt32(exactly: value)
        default: nil
        }
    }

    /// The keys, for `PropertyListDecoder`.
    private struct Keys: Decodable {

        enum CodingKeys: String, CodingKey {
            case abiVersion = "RTABIVersion"
            case contracts = "RTContracts"
            case targets = "RTTargets"
            case capabilities = "RTCapabilities"
            case capabilityUsage = "RTCapabilityUsage"
            case identifier = "CFBundleIdentifier"
            case name = "CFBundleName"
            case version = "CFBundleShortVersionString"
            case build = "CFBundleVersion"
        }

        struct Entry: Decodable {

            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case version = "Version"
                case kind = "Kind"
            }

            var name: String
            var version: UInt32
            var kind: String
        }

        var abiVersion: UInt32?
        var contracts: [Entry]?
        var targets: [String]?
        var capabilities: [String]?
        var capabilityUsage: [String: String]?
        var identifier: String?
        var name: String?
        var version: String?
        var build: String?
    }
}

/// A problem with the app's keys.
public enum AppInfoError: Error, Equatable, CustomStringConvertible {

    /// A required key, or the file, isn't there.
    case missing(String)

    case malformed(String)

    public var description: String {
        switch self {
        case .missing(let key): "the app has no \(key); is it a universal bundle from guest.py?"
        case .malformed(let key): "the app's \(key) is malformed"
        }
    }
}

extension ContractKind {

    /// The `Kind` string in `RTContracts`.
    init?(name: String) {
        switch name {
        case "contract": self = .contract
        case "callback": self = .callback
        default: return nil
        }
    }
}
