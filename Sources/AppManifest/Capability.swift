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

    /// The camera: a preview, photos and video.
    static func camera(usage: ManifestText) -> Capability {
        Capability("camera", usage: usage)
    }

    /// Recording sound: a video's, with the camera.
    static func microphone(usage: ManifestText) -> Capability {
        Capability("microphone", usage: usage)
    }

    /// The photos and videos the system keeps for the user. `.addOnly` is
    /// for an app that only saves what it made, such as a camera: it reads
    /// none.
    static func photoLibrary(_ access: PhotosAccess = .readWrite, usage: ManifestText) -> Capability {
        Capability("photoLibrary", usage: usage, options: ["access": access.rawValue])
    }

    /// Device location. `.always` also asks for background access.
    static func location(_ access: LocationAccess = .whenInUse, usage: ManifestText) -> Capability {
        Capability("location", usage: usage, options: ["access": access.rawValue])
    }

    /// Notifications the system shows for the app. The user is asked when
    /// the app asks, and there's no usage text: no platform shows one.
    static var notifications: Capability {
        Capability("notifications")
    }

    /// Notifications, with pushes from the app's server when `remote`, and
    /// scheduled ones that arrive on time when `exactTiming`: for an alarm
    /// clock or a calendar, which is who Android allows it. With
    /// `wakesApp`, a push with data only reaches the app when it's closed.
    static func notifications(remote: Bool = false, exactTiming: Bool = false, wakesApp: Bool = false) -> Capability {
        var options: [String: String] = [:]
        if remote {
            options["remote"] = "true"
        }
        if exactTiming {
            options["exactTiming"] = "true"
        }
        if wakesApp {
            options["wakesApp"] = "true"
        }
        return Capability("notifications", options: options)
    }

    /// Playing sound: media players. It prompts for nothing.
    static var audio: Capability {
        Capability("audio")
    }

    /// Playing sound, and with `background`, playing on when the app
    /// leaves the front: for a music or podcast app.
    static func audio(background: Bool) -> Capability {
        Capability("audio", options: background ? ["background": "true"] : [:])
    }

    /// Running in the background: the tasks `backgroundTasks` names, which
    /// the system starts from time to time, and time to finish something.
    /// It prompts for nothing.
    static var backgroundTasks: Capability {
        Capability("backgroundTasks")
    }

    /// The user's calendars and the events in them. `.writeOnly` is for
    /// an app that only adds events, such as a mail app with invitations:
    /// it reads none.
    static func calendars(_ access: CalendarAccess = .full, usage: ManifestText) -> Capability {
        Capability("calendars", usage: usage, options: ["access": access.rawValue])
    }

    /// The people in the user's address book. `.readOnly` is for an app
    /// that only looks people up, such as a mail app completing an
    /// address: it changes none.
    static func contacts(_ access: ContactsAccess = .readWrite, usage: ManifestText) -> Capability {
        Capability("contacts", usage: usage, options: ["access": access.rawValue])
    }

    /// Keeping secrets in the system's store: a token, a password. It
    /// prompts for nothing.
    static var secrets: Capability {
        Capability("secrets")
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

    /// The platform's file pickers, and the files the app is opened with
    /// (`documentTypes`). It prompts for nothing: the user's choice of a
    /// file is the permission.
    static var userFiles: Capability {
        Capability("userFiles")
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

/// What an app does with the user's photos.
public enum PhotosAccess: String, Sendable {

    /// Adding photos and videos, and reading none.
    case addOnly

    /// Browsing them, adding to them and deleting them.
    case readWrite
}

/// What an app does with the user's contacts.
public enum ContactsAccess: String, Sendable {

    /// Reading them, and adding, changing and removing them.
    case readWrite

    /// Reading them, and changing none.
    case readOnly
}

/// How much of the user's calendars an app asks for.
public enum CalendarAccess: String, Sendable {

    /// Reading events and changing them.
    case full

    /// Adding events, and reading none.
    case writeOnly
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
