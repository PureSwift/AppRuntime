import DynamicRuntime

/// What a notification says. How it sounds, how much it interrupts and its
/// buttons are its category's.
public struct NotificationContent: Equatable, Sendable {

    /// The text, already in the user's language.
    public var title: String
    public var subtitle: String
    public var body: String

    /// Which category it's of. None: the default one.
    public var categoryIdentifier: String?

    /// Notifications with the same one are grouped.
    public var threadIdentifier: String?

    /// The number on the app's icon once it's delivered. `nil`: unchanged.
    public var badge: Int?

    /// Delivered without sound, whatever its category says.
    public var isSilent: Bool

    /// The app's own values, handed back with the response.
    public var userInfo: [String: String]

    public init(
        title: String = "",
        subtitle: String = "",
        body: String = "",
        categoryIdentifier: String? = nil,
        threadIdentifier: String? = nil,
        badge: Int? = nil,
        isSilent: Bool = false,
        userInfo: [String: String] = [:]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.threadIdentifier = threadIdentifier
        self.badge = badge
        self.isSilent = isSilent
        self.userInfo = userInfo
    }

    /// As a record says it.
    init(_ record: any NotificationRecord) {
        let badge = record.badge()
        var userInfo: [String: String] = [:]
        for key in record.keys() {
            userInfo[key] = record.value(key)
        }
        self.init(
            title: record.title(),
            subtitle: record.subtitle(),
            body: record.body(),
            categoryIdentifier: record.category(),
            threadIdentifier: record.thread(),
            badge: badge < 0 ? nil : Int(badge),
            isSilent: record.isSilent(),
            userInfo: userInfo
        )
    }
}

/// When a notification is delivered. With none, it's shown now.
public struct NotificationTrigger: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case interval(Double)
        case date(Int64)
        case calendar(year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32)
    }

    let kind: Kind

    public let repeats: Bool

    /// After so many seconds. Repeating needs 60 or more.
    public static func timeInterval(_ seconds: Double, repeats: Bool = false) -> NotificationTrigger {
        NotificationTrigger(kind: .interval(seconds), repeats: repeats)
    }

    /// Once, at that moment.
    public static func date(millisecondsSince1970 milliseconds: Int64) -> NotificationTrigger {
        NotificationTrigger(kind: .date(milliseconds), repeats: false)
    }

    /// When the device's clock next matches the parts given, in its own
    /// time zone; repeating, every time it does. `weekday` is 1 for
    /// Sunday to 7 for Saturday.
    ///
    /// ```swift
    /// .calendar(hour: 7, minute: 0, repeats: true)               // every morning
    /// .calendar(hour: 7, minute: 0, weekday: 2, repeats: true)   // every Monday
    /// ```
    public static func calendar(
        year: Int? = nil,
        month: Int? = nil,
        day: Int? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        second: Int? = nil,
        weekday: Int? = nil,
        repeats: Bool = false
    ) -> NotificationTrigger {
        func part(_ value: Int?) -> Int32 {
            value.map { Int32(truncatingIfNeeded: $0) } ?? -1
        }
        return NotificationTrigger(kind: .calendar(
            year: part(year), month: part(month), day: part(day), hour: part(hour),
            minute: part(minute), second: part(second), weekday: part(weekday)
        ), repeats: repeats)
    }

    func apply(to record: any NotificationRecord) {
        switch kind {
        case .interval(let seconds):
            record.setInterval(seconds, repeats: repeats)
        case .date(let milliseconds):
            record.setDate(milliseconds)
        case .calendar(let year, let month, let day, let hour, let minute, let second, let weekday):
            record.setCalendar(year, month: month, day: day, hour: hour, minute: minute, second: second, weekday: weekday, repeats: repeats)
        }
    }
}

/// A notification to show: what it says, when, and the identifier it's
/// known by. Adding one with an identifier in use replaces the one before.
public struct NotificationRequest: Equatable, Sendable {

    public var identifier: String

    public var content: NotificationContent

    /// `nil`: now.
    public var trigger: NotificationTrigger?

    public init(identifier: String, content: NotificationContent, trigger: NotificationTrigger? = nil) {
        self.identifier = identifier
        self.content = content
        self.trigger = trigger
    }

    /// The host's record of it.
    func record() -> any NotificationRecord {
        let record = NotificationRecordProxy.make(identifier)
        record.setTitle(content.title)
        record.setSubtitle(content.subtitle)
        record.setBody(content.body)
        record.setCategory(content.categoryIdentifier)
        record.setThread(content.threadIdentifier)
        record.setBadge(content.badge.map { Int32(truncatingIfNeeded: max($0, 0)) } ?? -1)
        record.setSilent(content.isSilent)
        for (key, value) in content.userInfo {
            record.setValue(value, forKey: key)
        }
        trigger?.apply(to: record)
        return record
    }
}

/// A notification the system delivered.
public struct DeliveredNotification: Equatable, Sendable {

    /// Its request's identifier.
    public var identifier: String

    public var content: NotificationContent

    /// Whether it was a push.
    public var isRemote: Bool

    /// When it was delivered: milliseconds since 1970 UTC, where the host
    /// knows.
    public var date: Int64?

    public init(identifier: String, content: NotificationContent, isRemote: Bool = false, date: Int64? = nil) {
        self.identifier = identifier
        self.content = content
        self.isRemote = isRemote
        self.date = date
    }

    init(_ record: any NotificationRecord) {
        let delivered = record.delivered()
        self.init(identifier: record.identifier(), content: NotificationContent(record),
                  isRemote: record.isRemote(), date: delivered == 0 ? nil : delivered)
    }

    /// The content's `userInfo`.
    public var userInfo: [String: String] {
        content.userInfo
    }
}

/// What the user did with a notification.
public struct NotificationResponse: Equatable, Sendable {

    public var notification: DeliveredNotification

    /// The button's identifier, or `NotificationAction.defaultIdentifier`
    /// for a tap on the notification itself.
    public var actionIdentifier: String

    /// What the user typed, for a text action.
    public var text: String?

    public init(notification: DeliveredNotification, actionIdentifier: String = NotificationAction.defaultIdentifier, text: String? = nil) {
        self.notification = notification
        self.actionIdentifier = actionIdentifier
        self.text = text
    }
}
