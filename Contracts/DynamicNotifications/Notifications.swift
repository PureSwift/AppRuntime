import DynamicRuntime

/// Notifications the system shows for the app: now or scheduled, with
/// buttons, and what the user did with them
/// (`Documentation/Contracts/Notifications.md`). App code uses
/// `UserNotificationCenter`, which wraps this contract.
///
/// The system shows a notification, not the app: it's delivered while the
/// app is closed, so the host keeps what it needs to show it and its
/// buttons. Every operation completes through its `callback`, which the
/// host holds until it has called exactly one of its methods, on the main
/// thread.
///
/// `.notifications` prompts when the app asks, with
/// `requestAuthorization`, and never by itself.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `UNUserNotificationCenter` |
/// | Android | `NotificationManager`, with `AlarmManager` for scheduled ones |
/// | Linux | the shell's notification service |
/// | Browser | `showNotification` in a service worker |
@DynamicRuntime("org.pureswift.notifications.Notifications", requires: .notifications)
public protocol Notifications: AnyObject {

    static func current() -> Self

    // MARK: Permission

    /// Where things stand. Never prompts. Answers `didGetSettings`.
    func settings(_ callback: NotificationCallback)

    /// Asks the user, the first time; answers the same without asking
    /// after that. `options` are bits of `AuthorizationOptions`. Answers
    /// `didGetSettings`.
    func requestAuthorization(_ options: Int32, callback: NotificationCallback)

    /// Asks for scheduled notifications to arrive on time, where that's the
    /// user's to grant (Android). Answers `didGetSettings`.
    func requestExactTiming(_ callback: NotificationCallback)

    // MARK: Categories

    // The app's kinds of notification, set together: `beginCategories`,
    // then each category and its buttons, then `endCategories`, which
    // replaces those set before. The host keeps them across launches.

    func beginCategories()

    /// `name` is what the user sees it called in the system's settings.
    /// `interruption` is a `NotificationInterruption` raw value. `sound`:
    /// 0 the default sound, 1 none, 2 the file `soundName` in the bundle.
    func addCategory(_ identifier: String, name: String, interruption: Int32, sound: Int32, soundName: String?)

    /// A button of a category just added. `options` are bits of
    /// `NotificationActionOptions`: 1 destructive, 2 needs the device
    /// unlocked, 4 doesn't open the app.
    func addAction(_ category: String, identifier: String, title: String, options: Int32)

    /// A button that takes text from the user.
    func addTextAction(_ category: String, identifier: String, title: String, options: Int32, buttonTitle: String, placeholder: String)

    func endCategories()

    // MARK: Requests

    /// Shows the notification, or schedules it. One with an identifier in
    /// use replaces the one before. The record is read now: changing it
    /// afterwards changes nothing. Answers `didComplete`.
    func add(_ notification: NotificationRecord, callback: NotificationCallback)

    /// The identifiers scheduled and not yet delivered. Answers `didList`.
    func pending(_ callback: NotificationCallback)

    /// The identifiers delivered and still in the system's list. Answers
    /// `didList`.
    func delivered(_ callback: NotificationCallback)

    func removePending(_ identifiers: [String])

    func removeAllPending()

    func removeDelivered(_ identifiers: [String])

    func removeAllDelivered()

    /// The number on the app's icon; 0 clears it. Nothing where the
    /// platform has no number.
    func setBadgeCount(_ count: Int32)

    // MARK: Delivery

    /// How a notification is shown when it arrives with the app in front:
    /// bits of `NotificationPresentationOptions`.
    func setForegroundPresentation(_ options: Int32)

    /// Where deliveries and responses go. The host keeps a response that
    /// arrives while there's no delegate, the one that started the app
    /// among them, and reports it when one is set.
    func setDelegate(_ delegate: NotificationsDelegate?)
}

/// One notification: as the app asks for it, or as it was delivered.
@DynamicRuntime("org.pureswift.notifications.Record")
public protocol NotificationRecord: AnyObject {

    static func make(_ identifier: String) -> Self

    func identifier() -> String

    func setTitle(_ title: String)
    func title() -> String

    func setSubtitle(_ subtitle: String)
    func subtitle() -> String

    func setBody(_ body: String)
    func body() -> String

    /// Which category it's of. None: the default one.
    func setCategory(_ identifier: String?)
    func category() -> String?

    /// Notifications with the same thread are grouped.
    func setThread(_ identifier: String?)
    func thread() -> String?

    /// The number on the app's icon once it's delivered; -1 leaves it.
    func setBadge(_ count: Int32)
    func badge() -> Int32

    /// Delivered without sound, whatever its category says.
    func setSilent(_ silent: Bool)
    func isSilent() -> Bool

    /// The app's own values, handed back with the notification. `nil`
    /// removes one.
    func setValue(_ value: String?, forKey key: String)
    func keys() -> [String]
    func value(_ key: String) -> String?

    // One trigger; with none, the notification is shown now.

    /// After `seconds`. Repeating needs 60 or more.
    func setInterval(_ seconds: Double, repeats: Bool)

    /// Once, at that moment: milliseconds since 1970 UTC.
    func setDate(_ milliseconds: Int64)

    /// When the device's clock next matches the parts given, in its own
    /// time zone; -1 for a part that isn't given. `weekday` is 1 for
    /// Sunday to 7 for Saturday.
    func setCalendar(_ year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32, repeats: Bool)

    // The trigger, for the host to read.

    /// 0 none, 1 an interval, 2 a date, 3 calendar parts.
    func triggerKind() -> Int32
    func triggerRepeats() -> Bool
    /// An interval's seconds.
    func triggerInterval() -> Double
    /// A date's milliseconds since 1970 UTC.
    func triggerDate() -> Int64
    /// A calendar part: 0 the year, then month, day, hour, minute, second,
    /// and 6 the weekday. -1: not given.
    func triggerPart(_ index: Int32) -> Int32

    // Of a delivered one.

    /// Whether it was a push.
    func isRemote() -> Bool

    /// When it was delivered: milliseconds since 1970 UTC, or 0 before
    /// it is.
    func delivered() -> Int64
}
