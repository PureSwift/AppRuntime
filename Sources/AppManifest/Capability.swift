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

    /// Local notifications.
    static var notifications: Capability {
        Capability("notifications")
    }

    /// Local notifications, and push notifications when `remote`.
    static func notifications(remote: Bool) -> Capability {
        Capability("notifications", options: remote ? ["remote": "true"] : [:])
    }

    /// Motion sensors: accelerometer, gyroscope, pedometer.
    static func motion(usage: ManifestText) -> Capability {
        Capability("motion", usage: usage)
    }

    /// Reading NFC tags.
    static func nfc(usage: ManifestText) -> Capability {
        Capability("nfc", usage: usage)
    }

    /// Finding and connecting to devices on the local network.
    static func localNetwork(usage: ManifestText) -> Capability {
        Capability("localNetwork", usage: usage)
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

public extension Capability {

    /// Whether the app can't work without the hardware. Stores lean on it:
    /// the App Store hides a required capability's app from devices without
    /// the hardware. Capabilities are optional by default, and a contract
    /// whose hardware is missing reports itself unavailable.
    ///
    /// ```swift
    /// .bluetooth(usage: .localized("perm.bluetooth")).required()
    /// ```
    func required(_ isRequired: Bool = true) -> Capability {
        var capability = self
        capability.options["required"] = isRequired ? "true" : nil
        return capability
    }

    /// `required()`.
    var isRequired: Bool {
        options["required"] == "true"
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
