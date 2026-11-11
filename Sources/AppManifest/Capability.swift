/// Something the app may use, with the text that explains why (§7.3).
///
/// The names match the capabilities contracts require
/// (`@DynamicRuntime(…, requires: .bluetooth)`). Hosts turn each into their
/// own entries: a usage description on Apple platforms, permissions and
/// features on Android.
public struct Capability: Sendable, Equatable {

    /// The capability's name, such as `bluetooth`.
    public var name: String

    /// Why the app needs it, shown when the system asks the user.
    public var usage: ManifestText?

    /// Capability-specific settings, such as location's `access`.
    public var options: [String: String]

    public init(_ name: String, usage: ManifestText? = nil, options: [String: String] = [:]) {
        self.name = name
        self.usage = usage
        self.options = options
    }
}

public extension Capability {

    /// Bluetooth LE: scanning, connecting, GATT.
    static func bluetooth(usage: ManifestText) -> Capability {
        Capability("bluetooth", usage: usage)
    }

    static func camera(usage: ManifestText) -> Capability {
        Capability("camera", usage: usage)
    }

    /// Device location. `.always` also asks for background access.
    static func location(_ access: LocationAccess = .whenInUse, usage: ManifestText) -> Capability {
        Capability("location", usage: usage, options: ["access": access.rawValue])
    }

    /// Local and push notifications.
    static var notifications: Capability {
        Capability("notifications")
    }

    /// Network access: URL sessions, sockets where the platform gates them.
    static var network: Capability {
        Capability("network")
    }

    /// Hardware graphics, such as OpenGL ES 2.
    static func graphics(_ api: GraphicsAPI = .gles2) -> Capability {
        Capability("graphics", options: ["api": api.rawValue])
    }
}

/// `Capability.location(_:usage:)`.
public enum LocationAccess: String, Sendable {

    /// While the app is in use.
    case whenInUse

    /// In the background too.
    case always
}

/// `Capability.graphics(_:)`.
public enum GraphicsAPI: String, Sendable {

    case gles2
}
