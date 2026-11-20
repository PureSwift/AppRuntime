/// A capability a contract requires and a manifest grants (§7.3).
///
/// Contracts name the capability they need (`requires: .bluetooth`); the host
/// refuses `rt_class` for contracts whose capability the app didn't declare.
public struct Capability: RawRepresentable, Equatable, Hashable, Sendable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension Capability {

    static var bluetooth: Capability { Capability("bluetooth") }

    static var camera: Capability { Capability("camera") }

    static var location: Capability { Capability("location") }

    static var notifications: Capability { Capability("notifications") }

    static var network: Capability { Capability("network") }

    static var graphics: Capability { Capability("graphics") }

    static var motion: Capability { Capability("motion") }

    static var nfc: Capability { Capability("nfc") }

    /// Running in the background: tasks the system starts, and time to
    /// finish. It prompts for nothing.
    static var backgroundTasks: Capability { Capability("backgroundTasks") }

    /// The platform's file pickers. It prompts for nothing.
    static var userFiles: Capability { Capability("userFiles") }
}

extension Capability: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension Capability: CustomStringConvertible {

    public var description: String {
        rawValue
    }
}
