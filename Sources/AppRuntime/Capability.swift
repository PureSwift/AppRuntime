//
//  Capability.swift
//  AppRuntime
//

/// A capability an app can request in its manifest.
public struct Capability: RawRepresentable, Equatable, Hashable, Codable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - ExpressibleByStringLiteral

extension Capability: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension Capability: CustomStringConvertible, CustomDebugStringConvertible {

    public var description: String {
        rawValue
    }

    public var debugDescription: String {
        rawValue
    }
}

// MARK: - Definitions

public extension Capability {

    /// Access to the display / compositor.
    static var display: Capability { "Display" }

    /// Access to audio output and capture.
    static var audio: Capability { "Audio" }

    /// Network access.
    static var network: Capability { "Network" }

    /// Access to Bluetooth radios.
    static var bluetooth: Capability { "Bluetooth" }

    /// Access to NFC hardware.
    static var nfc: Capability { "NFC" }
}
