import DynamicRuntime

/// Guest-side names for what the notification contracts carry.

/// What the app means to use, when it asks the user.
public struct AuthorizationOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let alert = AuthorizationOptions(rawValue: 1 << 0)
    public static let sound = AuthorizationOptions(rawValue: 1 << 1)
    public static let badge = AuthorizationOptions(rawValue: 1 << 2)

    /// Deliver quietly without asking, where the platform can (iOS): the
    /// status is then `limited`. Elsewhere it asks as usual.
    public static let provisional = AuthorizationOptions(rawValue: 1 << 3)
}

/// How a notification is shown when it arrives with the app in front.
public struct NotificationPresentationOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let banner = NotificationPresentationOptions(rawValue: 1 << 0)
    /// In the system's list of notifications.
    public static let list = NotificationPresentationOptions(rawValue: 1 << 1)
    public static let sound = NotificationPresentationOptions(rawValue: 1 << 2)
    public static let badge = NotificationPresentationOptions(rawValue: 1 << 3)

    /// As when the app isn't in front.
    public static let all: NotificationPresentationOptions = [.banner, .list, .sound, .badge]
}

/// Where the user's permission stands, and what it lets through.
public struct NotificationSettings: Equatable, Sendable {

    /// `granted`, or `limited` for quiet delivery, lets notifications show.
    public var authorizationStatus: PermissionStatus

    /// What the user left on.
    public var alerts: Bool
    public var sounds: Bool
    public var badges: Bool

    /// Whether a scheduled notification arrives on time. Without it
    /// Android delivers late: by minutes, and longer while the device
    /// sleeps.
    public var exactTiming: Bool

    /// Whether a scheduled notification arrives with the app closed. A
    /// browser's doesn't.
    public var deliversWhenClosed: Bool

    public init(
        authorizationStatus: PermissionStatus,
        alerts: Bool = false,
        sounds: Bool = false,
        badges: Bool = false,
        exactTiming: Bool = false,
        deliversWhenClosed: Bool = false
    ) {
        self.authorizationStatus = authorizationStatus
        self.alerts = alerts
        self.sounds = sounds
        self.badges = badges
        self.exactTiming = exactTiming
        self.deliversWhenClosed = deliversWhenClosed
    }

    /// Whether a notification the app adds is shown.
    public var isAuthorized: Bool {
        authorizationStatus == .granted || authorizationStatus == .limited
    }

    // The contract's `enabled` bits.
    static let alertsBit: Int32 = 1 << 0
    static let soundsBit: Int32 = 1 << 1
    static let badgesBit: Int32 = 1 << 2
    static let exactTimingBit: Int32 = 1 << 3
    static let deliversWhenClosedBit: Int32 = 1 << 4

    /// From what `didGetSettings` carries. A status from a newer host is
    /// one the app can't use.
    public init(status: Int32, enabled: Int32) {
        self.init(
            authorizationStatus: PermissionStatus(rawValue: status) ?? .unavailable,
            alerts: enabled & Self.alertsBit != 0,
            sounds: enabled & Self.soundsBit != 0,
            badges: enabled & Self.badgesBit != 0,
            exactTiming: enabled & Self.exactTimingBit != 0,
            deliversWhenClosed: enabled & Self.deliversWhenClosedBit != 0
        )
    }

    /// The contract's `enabled` bits.
    public var enabledBits: Int32 {
        (alerts ? Self.alertsBit : 0) | (sounds ? Self.soundsBit : 0) | (badges ? Self.badgesBit : 0)
            | (exactTiming ? Self.exactTimingBit : 0) | (deliversWhenClosed ? Self.deliversWhenClosedBit : 0)
    }
}

/// Why a notification operation failed.
public enum NotificationError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. Hosts never send it.
    case cancelled = 1

    /// The user hasn't allowed notifications.
    case notAuthorized = 2

    /// Not called from a user action. A browser asks only while it handles
    /// a tap or a key.
    case notAllowed = 3

    /// This host can't: push, with no push service.
    case unsupported = 4

    /// A moment that has passed, a repeating interval under 60 seconds,
    /// calendar parts that match no date, or no identifier.
    case invalid = 5

    /// The host keeps no more pending requests.
    case limitReached = 6

    /// Push, and the manifest doesn't say `.notifications(remote: true)`.
    case notDeclared = 7

    /// The push service can't be reached now.
    case unavailable = 8
}

/// How much a category's notifications interrupt.
public enum NotificationInterruption: Int32, Sendable {

    /// In the list, with no sound or banner.
    case passive = 0

    case active = 1

    /// Through a focus or do-not-disturb, where the user allows.
    case timeSensitive = 2
}

/// What a category's notifications sound like.
public enum NotificationSound: Equatable, Sendable {

    case `default`

    case none

    /// A sound file in the app's bundle.
    case named(String)

    var kind: Int32 {
        switch self {
        case .default: 0
        case .none: 1
        case .named: 2
        }
    }

    var name: String? {
        if case .named(let name) = self {
            return name
        }
        return nil
    }
}

/// How a button behaves.
public struct NotificationActionOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Shown as something that removes or ends.
    public static let destructive = NotificationActionOptions(rawValue: 1 << 0)

    /// Needs the device unlocked first.
    public static let authenticationRequired = NotificationActionOptions(rawValue: 1 << 1)
}

/// A button on a notification. Choosing one opens the app, and the choice
/// arrives as a `NotificationResponse`.
public struct NotificationAction: Equatable, Sendable {

    /// The action of a tap on the notification itself.
    public static let defaultIdentifier = ""

    public var identifier: String

    public var title: String

    public var options: NotificationActionOptions

    /// For a button that takes text: what its send button says, and what
    /// its empty field shows.
    public var textInput: TextInput?

    public struct TextInput: Equatable, Sendable {

        public var buttonTitle: String

        public var placeholder: String

        public init(buttonTitle: String, placeholder: String) {
            self.buttonTitle = buttonTitle
            self.placeholder = placeholder
        }
    }

    public init(identifier: String, title: String, options: NotificationActionOptions = []) {
        self.identifier = identifier
        self.title = title
        self.options = options
        self.textInput = nil
    }

    /// A button that takes text from the user. Where a host can't take
    /// text in a notification, it opens the app with none.
    public static func textInput(
        identifier: String,
        title: String,
        options: NotificationActionOptions = [],
        buttonTitle: String,
        placeholder: String = ""
    ) -> NotificationAction {
        var action = NotificationAction(identifier: identifier, title: title, options: options)
        action.textInput = TextInput(buttonTitle: buttonTitle, placeholder: placeholder)
        return action
    }
}

/// A kind of notification: what it's called, its buttons, and how it
/// behaves. On Android it's a channel: the user can change its sound and
/// importance in Settings, and after it first exists the app can't.
public struct NotificationCategory: Equatable, Sendable {

    /// What a content's `categoryIdentifier`, and a push, name.
    public var identifier: String

    /// What the user sees it called in the system's settings.
    public var name: String

    /// Its buttons, in order. Hosts show at least two.
    public var actions: [NotificationAction]

    public var interruption: NotificationInterruption

    public var sound: NotificationSound

    public init(
        identifier: String,
        name: String,
        actions: [NotificationAction] = [],
        interruption: NotificationInterruption = .active,
        sound: NotificationSound = .default
    ) {
        self.identifier = identifier
        self.name = name
        self.actions = actions
        self.interruption = interruption
        self.sound = sound
    }
}

/// Which push service an address is for. The app's server speaks to each.
public struct PushService: RawRepresentable, Equatable, Hashable, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Apple's. The address is the device token, in hex.
    public static let apns = PushService(rawValue: 0)

    /// Firebase Cloud Messaging. The address is the registration token.
    public static let fcm = PushService(rawValue: 1)

    /// Web Push (RFC 8030). The address is the endpoint URL, with keys.
    public static let webPush = PushService(rawValue: 2)
}

/// Where the app's server sends a push for this install.
public struct PushSubscription: Equatable, Hashable, Sendable {

    public var service: PushService

    /// The APNs device token in hex, the FCM registration token, or the
    /// Web Push endpoint URL.
    public var address: String

    /// Web Push's `p256dh` and `auth` keys, base64url. `nil` elsewhere.
    public var publicKey: String?
    public var authSecret: String?

    /// APNs's sandbox, for a development build.
    public var isDevelopment: Bool

    public init(service: PushService, address: String, publicKey: String? = nil, authSecret: String? = nil, isDevelopment: Bool = false) {
        self.service = service
        self.address = address
        self.publicKey = publicKey
        self.authSecret = authSecret
        self.isDevelopment = isDevelopment
    }
}
