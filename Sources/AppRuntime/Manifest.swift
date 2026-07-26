//
//  Manifest.swift
//  
//
//  Created by Alsey Coleman Miller on 3/8/22.
//

/// App manifest
public struct Manifest: Equatable, Hashable, Codable, Identifiable {
    
    enum CodingKeys: String, CodingKey {
        case formatVersion
        case id
        case name
        case appDescription = "description"
        case sdk
        case executable
        case version
        case build
        case copyright
        case capabilities
        case architectures
    }

    /// Bundle format specification version.
    public let formatVersion: Int

    /// Reverse DNS bundle ID
    public let id: String
    
    /// Human-readable name
    public let name: String
    
    /// Human-readable description
    public let appDescription: String
    
    /// SDK version this app was compiled against.
    public let sdk: SDKVersion
    
    /// Name of the binary executable.
    public let executable: String
    
    /// App version
    public let version: String
    
    /// App build number
    public let build: String
    
    /// App copyright
    public let copyright: String?
    
    /// List of capabilities
    public let capabilities: [String]?

    /// Architectures included in the bundle's `bin/` directory.
    public let architectures: [Arch]

    public init(
        formatVersion: Int = Manifest.currentFormatVersion,
        id: String,
        name: String,
        appDescription: String,
        sdk: SDKVersion,
        executable: String,
        version: String,
        build: String,
        copyright: String? = nil,
        capabilities: [String]? = nil,
        architectures: [Arch]
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.appDescription = appDescription
        self.sdk = sdk
        self.executable = executable
        self.version = version
        self.build = build
        self.copyright = copyright
        self.capabilities = capabilities
        self.architectures = architectures
    }
}

public extension Manifest {

    /// The current bundle format specification version.
    static var currentFormatVersion: Int { 1 }
}

// MARK: - JSON

#if canImport(Foundation)
import Foundation

public extension Manifest {

    /// Standard file name of the manifest inside a bundle.
    static var fileName: String { "manifest.json" }

    /// Decode a manifest from JSON data.
    init(json data: Data) throws {
        self = try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Encode the manifest as JSON data.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
#endif
