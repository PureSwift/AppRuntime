import Dispatch
import DynamicNotifications
import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeHost

// MARK: - What a host is handed

/// The parts of a calendar trigger that were given.
public struct HostNotificationDateParts: Equatable, Sendable {

    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var second: Int?

    /// 1 for Sunday to 7 for Saturday.
    public var weekday: Int?

    public init(year: Int? = nil, month: Int? = nil, day: Int? = nil, hour: Int? = nil, minute: Int? = nil, second: Int? = nil, weekday: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.weekday = weekday
    }

    public var isEmpty: Bool {
        self == HostNotificationDateParts()
    }

    /// For Foundation's calendar, and for `UNCalendarNotificationTrigger`.
    public var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second, weekday: weekday)
    }

    /// Whether each part is one a clock or a calendar can show.
    public var isValid: Bool {
        func within(_ value: Int?, _ range: ClosedRange<Int>) -> Bool {
            value.map(range.contains) ?? true
        }
        guard !isEmpty, within(month, 1...12), within(day, 1...31), within(hour, 0...23),
              within(minute, 0...59), within(second, 0...59), within(weekday, 1...7), within(year, 1...9999) else {
            return false
        }
        if let month, let day {
            // The most days the month ever has.
            let longest = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            return day <= longest
        }
        return true
    }
}

/// When a notification is delivered.
public enum HostNotificationTrigger: Equatable, Sendable {

    case interval(seconds: Double, repeats: Bool)

    /// Milliseconds since 1970 UTC.
    case date(milliseconds: Int64)

    case calendar(HostNotificationDateParts, repeats: Bool)

    public var repeats: Bool {
        switch self {
        case .interval(_, let repeats), .calendar(_, let repeats): repeats
        case .date: false
        }
    }

    /// When it next fires after `date`: the moment it was added, or the
    /// last time it fired. `nil`: never. For a host that keeps time
    /// itself, where the system doesn't.
    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let seconds, _):
            return seconds > 0 ? date.addingTimeInterval(seconds) : nil
        case .date(let milliseconds):
            let moment = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            return moment > date ? moment : nil
        case .calendar(let parts, _):
            guard parts.isValid else { return nil }
            // A time the clocks skip, when they go forward, is the next one
            // they show that day. A day the year lacks, 29 February, isn't
            // the day after: it waits for a year that has it.
            if let adjusted = calendar.nextDate(after: date, matching: parts.components, matchingPolicy: .nextTime) {
                let found = calendar.dateComponents([.year, .month, .day, .weekday], from: adjusted)
                let sameDay = (parts.year ?? found.year) == found.year && (parts.month ?? found.month) == found.month
                    && (parts.day ?? found.day) == found.day && (parts.weekday ?? found.weekday) == found.weekday
                if sameDay {
                    return adjusted
                }
            }
            return calendar.nextDate(after: date, matching: parts.components, matchingPolicy: .strict)
        }
    }
}

/// One notification, as the app asked for it or as it was delivered.
public struct HostNotification: Equatable, Sendable {

    public var identifier: String

    public var title: String
    public var subtitle: String
    public var body: String

    /// `nil`: the default category.
    public var category: String?

    public var thread: String?

    /// `nil`: leave the app's badge as it is.
    public var badge: Int?

    public var isSilent: Bool

    public var userInfo: [String: String]

    /// `nil`: now.
    public var trigger: HostNotificationTrigger?

    /// Whether it was a push.
    public var isRemote: Bool

    /// When it was delivered: milliseconds since 1970 UTC, or 0.
    public var delivered: Int64

    public init(
        identifier: String,
        title: String = "",
        subtitle: String = "",
        body: String = "",
        category: String? = nil,
        thread: String? = nil,
        badge: Int? = nil,
        isSilent: Bool = false,
        userInfo: [String: String] = [:],
        trigger: HostNotificationTrigger? = nil,
        isRemote: Bool = false,
        delivered: Int64 = 0
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.thread = thread
        self.badge = badge
        self.isSilent = isSilent
        self.userInfo = userInfo
        self.trigger = trigger
        self.isRemote = isRemote
        self.delivered = delivered
    }

    /// As a record says it: the guest's, which the host reads through the
    /// contract, or the host's own.
    public init(_ record: any NotificationRecord) {
        let badge = record.badge()
        var userInfo: [String: String] = [:]
        for key in record.keys() {
            userInfo[key] = record.value(key)
        }
        let trigger: HostNotificationTrigger?
        switch record.triggerKind() {
        case 1:
            trigger = .interval(seconds: record.triggerInterval(), repeats: record.triggerRepeats())
        case 2:
            trigger = .date(milliseconds: record.triggerDate())
        case 3:
            func part(_ index: Int32) -> Int? {
                let value = record.triggerPart(index)
                return value < 0 ? nil : Int(value)
            }
            trigger = .calendar(HostNotificationDateParts(
                year: part(0), month: part(1), day: part(2), hour: part(3), minute: part(4), second: part(5), weekday: part(6)
            ), repeats: record.triggerRepeats())
        default:
            trigger = nil
        }
        self.init(
            identifier: record.identifier(),
            title: record.title(),
            subtitle: record.subtitle(),
            body: record.body(),
            category: record.category(),
            thread: record.thread(),
            badge: badge < 0 ? nil : Int(badge),
            isSilent: record.isSilent(),
            userInfo: userInfo,
            trigger: trigger,
            isRemote: record.isRemote(),
            delivered: record.delivered()
        )
    }

    /// The shortest interval a repeating trigger may have, in seconds.
    public static let shortestRepeat: Double = 60

    /// Why it can't be added at `now`, when it can't: no identifier, a
    /// moment that has passed, a repeating interval that's too short, or
    /// calendar parts that match no date.
    public func problem(at now: Date, calendar: Calendar = .current) -> NotificationError? {
        guard !identifier.isEmpty else {
            return .invalid
        }
        switch trigger {
        case nil:
            return nil
        case .interval(let seconds, let repeats):
            return seconds > 0 && (!repeats || seconds >= Self.shortestRepeat) ? nil : .invalid
        case .date, .calendar:
            return trigger?.nextDate(after: now, calendar: calendar) == nil ? .invalid : nil
        }
    }
}

/// What shows a host's notifications: the part of the notification
/// contracts that's the platform's own. Everything is called on the main
/// thread, and every completion is called on it, once.
///
/// A presenter keeps scheduled notifications and shows them, with the app
/// open or closed, where its platform can; `deliversWhenClosed` in its
/// settings says whether it does.
public protocol NotificationPresenter: AnyObject {

    /// Where the user's permission stands. Never prompts.
    func settings(_ completion: @escaping (NotificationSettings) -> Void)

    /// Asks the user, the first time.
    func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void)

    /// Asks for exact timing, where it's the user's to grant.
    func requestExactTiming(_ completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void)

    /// The app's categories, replacing those before. Kept across launches.
    func setCategories(_ categories: [NotificationCategory])

    /// Shows or schedules a notification that has been checked, replacing
    /// one with the same identifier. `nil`: done.
    func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void)

    func pending(_ completion: @escaping ([String]) -> Void)

    func delivered(_ completion: @escaping ([String]) -> Void)

    /// `nil`: all of them.
    func removePending(_ identifiers: [String]?)

    /// `nil`: all of them.
    func removeDelivered(_ identifiers: [String]?)

    func setBadgeCount(_ count: Int)

    func setForegroundPresentation(_ options: NotificationPresentationOptions)

    /// Asks the platform's push service for the app's address.
    func registerForPush(serverKey: String?, completion: @escaping (Result<PushSubscription, NotificationError>) -> Void)

    func unregisterForPush(_ completion: @escaping (NotificationError?) -> Void)
}

public extension NotificationPresenter {

    /// Timing is exact already, or not the user's to change.
    func requestExactTiming(_ completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        settings { completion(.success($0)) }
    }

    /// No push service.
    func registerForPush(serverKey: String?, completion: @escaping (Result<PushSubscription, NotificationError>) -> Void) {
        completion(.failure(.unsupported))
    }

    func unregisterForPush(_ completion: @escaping (NotificationError?) -> Void) {
        completion(.unsupported)
    }
}

// MARK: - The contracts

/// The `Notifications` contract over a host's `NotificationPresenter`: what
/// every host written in Swift shares.
///
/// It checks each request before the presenter sees it, refuses one the
/// user hasn't allowed, turns records into values and back, and keeps what
/// the user did with a notification until the guest listens.
///
/// ```swift
/// HostNotifications.presenter = MyNotificationCentre()
/// HostNotifications.declaresRemote = remoteIsInTheManifest
/// HostNotificationsModule.register(in: runtime)
/// // When the user taps a notification, or one of its buttons:
/// HostNotifications.responded(to: notification, action: "snooze")
/// // When one arrives while the app runs:
/// HostNotifications.received(notification)
/// ```
///
/// Main thread only.
public final class HostNotifications: Notifications {

    /// The host's notification centre. Without one, notifications are
    /// `unavailable` and adding one fails with `unsupported`.
    nonisolated(unsafe) public static var presenter: (any NotificationPresenter)?

    /// Runs an answer on the main thread, after the call that asked has
    /// returned. The default is the main dispatch queue; a host with a
    /// loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }

    /// The time, for checking a request. Tests set it.
    nonisolated(unsafe) public static var now: () -> Date = { Date() }

    /// Whether the manifest declares push (`.notifications(remote: true)`).
    /// Without it registering fails with `notDeclared`.
    nonisolated(unsafe) public static var declaresRemote = false

    /// The permission as the presenter last reported it: what the
    /// built-in `Permissions.status`, which can't wait, answers with.
    nonisolated(unsafe) public internal(set) static var lastStatus: PermissionStatus = .notDetermined

    // One of each for the life of the process: a guest keeps the ones it
    // first asked for.
    nonisolated(unsafe) private static let instance = HostNotifications()

    nonisolated(unsafe) static let push = HostPushNotifications()

    private var delegate: (any NotificationsDelegate)?

    /// The categories between `beginCategories` and `endCategories`.
    private var categories: [NotificationCategory]?

    /// What the user did while nothing listened.
    private var waiting: [(notification: HostNotification, action: String, text: String?)] = []

    init() { }

    public static func current() -> HostNotifications {
        instance
    }

    // MARK: Host side

    /// A notification was delivered while the app is running: local or
    /// pushed, shown or not. Dropped when the guest isn't listening.
    public static func received(_ notification: HostNotification) {
        guard let delegate = instance.delegate else { return }
        delegate.didReceive(HostNotificationRecord(stamped(notification)))
    }

    /// The user tapped a notification (`action` empty) or chose one of its
    /// buttons. The guest hears now, or when it starts to listen: so the
    /// response that started the app isn't lost.
    public static func responded(to notification: HostNotification, action: String = "", text: String? = nil) {
        let notification = stamped(notification)
        if let delegate = instance.delegate {
            delegate.didRespond(HostNotificationRecord(notification), action: action, text: text)
        } else {
            instance.waiting.append((notification, action, text))
        }
    }

    /// The app's push address changed while it runs.
    public static func pushSubscriptionChanged(_ subscription: PushSubscription) {
        push.delegate?.didChangeRegistration(subscription.service.rawValue, address: subscription.address,
                                             publicKey: subscription.publicKey, authSecret: subscription.authSecret,
                                             development: subscription.isDevelopment)
    }

    /// Asks the presenter where the permission stands, so `lastStatus` is
    /// right before the guest first asks. A host calls it at launch and
    /// when the app comes forward.
    public static func refreshStatus() {
        presenter?.settings { lastStatus = $0.authorizationStatus }
    }

    /// Forgets the presenter, the delegates and what waits, for tests and
    /// for a host that starts the guest again.
    public static func reset() {
        presenter = nil
        declaresRemote = false
        lastStatus = .notDetermined
        now = { Date() }
        instance.delegate = nil
        instance.waiting = []
        instance.categories = nil
        push.delegate = nil
    }

    /// With the time it was delivered, if the host didn't say.
    private static func stamped(_ notification: HostNotification) -> HostNotification {
        guard notification.delivered == 0 else { return notification }
        var notification = notification
        notification.delivered = Int64((now().timeIntervalSince1970 * 1000).rounded())
        return notification
    }

    /// Calls `answer` with the callback, on the main thread and later.
    static func later<Callback>(_ callback: Callback, _ answer: @escaping (Callback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func answer(_ callback: any NotificationCallback, _ result: Result<NotificationSettings, NotificationError>) {
        if case .success(let settings) = result {
            lastStatus = settings.authorizationStatus
        }
        later(callback) { callback in
            switch result {
            case .success(let settings):
                callback.didGetSettings(settings.authorizationStatus.rawValue, enabled: settings.enabledBits)
            case .failure(let error):
                callback.didFail(error.rawValue)
            }
        }
    }

    // MARK: Notifications

    public func settings(_ callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.answer(callback, .success(NotificationSettings(authorizationStatus: .unavailable)))
            return
        }
        presenter.settings { Self.answer(callback, .success($0)) }
    }

    public func requestAuthorization(_ options: Int32, callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.answer(callback, .success(NotificationSettings(authorizationStatus: .unavailable)))
            return
        }
        presenter.requestAuthorization(AuthorizationOptions(rawValue: options)) { Self.answer(callback, $0) }
    }

    public func requestExactTiming(_ callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.answer(callback, .success(NotificationSettings(authorizationStatus: .unavailable)))
            return
        }
        presenter.requestExactTiming { Self.answer(callback, $0) }
    }

    public func beginCategories() {
        categories = []
    }

    public func addCategory(_ identifier: String, name: String, interruption: Int32, sound: Int32, soundName: String?) {
        guard !identifier.isEmpty, categories?.contains(where: { $0.identifier == identifier }) == false else { return }
        let named: NotificationSound
        switch sound {
        case 1: named = .none
        case 2: named = soundName.map(NotificationSound.named) ?? .default
        default: named = .default
        }
        // A level from a newer guest interrupts as usual.
        categories?.append(NotificationCategory(identifier: identifier, name: name,
                                                interruption: NotificationInterruption(rawValue: interruption) ?? .active, sound: named))
    }

    public func addAction(_ category: String, identifier: String, title: String, options: Int32) {
        add(NotificationAction(identifier: identifier, title: title, options: NotificationActionOptions(rawValue: options)), to: category)
    }

    public func addTextAction(_ category: String, identifier: String, title: String, options: Int32, buttonTitle: String, placeholder: String) {
        add(.textInput(identifier: identifier, title: title, options: NotificationActionOptions(rawValue: options),
                       buttonTitle: buttonTitle, placeholder: placeholder), to: category)
    }

    /// A button with no identifier couldn't be told from a tap.
    private func add(_ action: NotificationAction, to category: String) {
        guard !action.identifier.isEmpty, let index = categories?.firstIndex(where: { $0.identifier == category }) else { return }
        categories?[index].actions.append(action)
    }

    public func endCategories() {
        guard let categories else { return }
        self.categories = nil
        Self.presenter?.setCategories(categories)
    }

    public func add(_ notification: any NotificationRecord, callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.later(callback) { $0.didFail(NotificationError.unsupported.rawValue) }
            return
        }
        // Read now: what the guest does to the record later changes nothing.
        let notification = HostNotification(notification)
        if let problem = notification.problem(at: Self.now()) {
            Self.later(callback) { $0.didFail(problem.rawValue) }
            return
        }
        presenter.settings { settings in
            Self.lastStatus = settings.authorizationStatus
            guard settings.isAuthorized else {
                // Where a platform would drop it and say nothing.
                Self.later(callback) { $0.didFail(NotificationError.notAuthorized.rawValue) }
                return
            }
            presenter.add(notification) { error in
                Self.later(callback) { callback in
                    if let error {
                        callback.didFail(error.rawValue)
                    } else {
                        callback.didComplete()
                    }
                }
            }
        }
    }

    public func pending(_ callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.later(callback) { $0.didList([]) }
            return
        }
        presenter.pending { identifiers in
            Self.later(callback) { $0.didList(identifiers) }
        }
    }

    public func delivered(_ callback: any NotificationCallback) {
        guard let presenter = Self.presenter else {
            Self.later(callback) { $0.didList([]) }
            return
        }
        presenter.delivered { identifiers in
            Self.later(callback) { $0.didList(identifiers) }
        }
    }

    public func removePending(_ identifiers: [String]) {
        Self.presenter?.removePending(identifiers)
    }

    public func removeAllPending() {
        Self.presenter?.removePending(nil)
    }

    public func removeDelivered(_ identifiers: [String]) {
        Self.presenter?.removeDelivered(identifiers)
    }

    public func removeAllDelivered() {
        Self.presenter?.removeDelivered(nil)
    }

    public func setBadgeCount(_ count: Int32) {
        Self.presenter?.setBadgeCount(Int(max(count, 0)))
    }

    public func setForegroundPresentation(_ options: Int32) {
        Self.presenter?.setForegroundPresentation(NotificationPresentationOptions(rawValue: options))
    }

    public func setDelegate(_ delegate: (any NotificationsDelegate)?) {
        self.delegate = delegate
        guard delegate != nil, !waiting.isEmpty else { return }
        let held = MainThreadHeld(self)
        Self.deliver {
            // Still listening, and to the same notifications object.
            guard let notifications = held.take(), let delegate = notifications.delegate else { return }
            let waiting = notifications.waiting
            notifications.waiting = []
            for response in waiting {
                delegate.didRespond(HostNotificationRecord(response.notification), action: response.action, text: response.text)
            }
        }
    }
}

/// The `PushNotifications` contract over the same presenter.
public final class HostPushNotifications: PushNotifications {

    var delegate: (any PushDelegate)?

    init() { }

    public static func shared() -> HostPushNotifications {
        HostNotifications.push
    }

    public func register(_ serverKey: String?, callback: any PushCallback) {
        guard HostNotifications.declaresRemote else {
            HostNotifications.later(callback) { $0.didFail(NotificationError.notDeclared.rawValue) }
            return
        }
        guard let presenter = HostNotifications.presenter else {
            HostNotifications.later(callback) { $0.didFail(NotificationError.unsupported.rawValue) }
            return
        }
        presenter.registerForPush(serverKey: serverKey) { result in
            HostNotifications.later(callback) { callback in
                switch result {
                case .success(let subscription):
                    callback.didRegister(subscription.service.rawValue, address: subscription.address,
                                         publicKey: subscription.publicKey, authSecret: subscription.authSecret,
                                         development: subscription.isDevelopment)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func unregister(_ callback: any PushCallback) {
        guard HostNotifications.declaresRemote else {
            HostNotifications.later(callback) { $0.didFail(NotificationError.notDeclared.rawValue) }
            return
        }
        guard let presenter = HostNotifications.presenter else {
            HostNotifications.later(callback) { $0.didFail(NotificationError.unsupported.rawValue) }
            return
        }
        presenter.unregisterForPush { error in
            HostNotifications.later(callback) { callback in
                if let error {
                    callback.didFail(error.rawValue)
                } else {
                    callback.didComplete()
                }
            }
        }
    }

    public func setDelegate(_ delegate: (any PushDelegate)?) {
        self.delegate = delegate
    }
}

/// A notification as the contract carries it: the guest fills one in to
/// add, and reads one that was delivered.
public final class HostNotificationRecord: NotificationRecord {

    public internal(set) var notification: HostNotification

    public init(_ notification: HostNotification) {
        self.notification = notification
    }

    public static func make(_ identifier: String) -> HostNotificationRecord {
        HostNotificationRecord(HostNotification(identifier: identifier))
    }

    public func identifier() -> String { notification.identifier }

    public func setTitle(_ title: String) { notification.title = title }
    public func title() -> String { notification.title }

    public func setSubtitle(_ subtitle: String) { notification.subtitle = subtitle }
    public func subtitle() -> String { notification.subtitle }

    public func setBody(_ body: String) { notification.body = body }
    public func body() -> String { notification.body }

    public func setCategory(_ identifier: String?) { notification.category = identifier }
    public func category() -> String? { notification.category }

    public func setThread(_ identifier: String?) { notification.thread = identifier }
    public func thread() -> String? { notification.thread }

    public func setBadge(_ count: Int32) { notification.badge = count < 0 ? nil : Int(count) }
    public func badge() -> Int32 { notification.badge.map { Int32(clamping: $0) } ?? -1 }

    public func setSilent(_ silent: Bool) { notification.isSilent = silent }
    public func isSilent() -> Bool { notification.isSilent }

    public func setValue(_ value: String?, forKey key: String) { notification.userInfo[key] = value }
    public func keys() -> [String] { notification.userInfo.keys.sorted() }
    public func value(_ key: String) -> String? { notification.userInfo[key] }

    public func setInterval(_ seconds: Double, repeats: Bool) {
        notification.trigger = .interval(seconds: seconds, repeats: repeats)
    }

    public func setDate(_ milliseconds: Int64) {
        notification.trigger = .date(milliseconds: milliseconds)
    }

    public func setCalendar(_ year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32, repeats: Bool) {
        func part(_ value: Int32) -> Int? {
            value < 0 ? nil : Int(value)
        }
        notification.trigger = .calendar(HostNotificationDateParts(
            year: part(year), month: part(month), day: part(day), hour: part(hour),
            minute: part(minute), second: part(second), weekday: part(weekday)
        ), repeats: repeats)
    }

    public func triggerKind() -> Int32 {
        switch notification.trigger {
        case nil: 0
        case .interval: 1
        case .date: 2
        case .calendar: 3
        }
    }

    public func triggerRepeats() -> Bool { notification.trigger?.repeats ?? false }

    public func triggerInterval() -> Double {
        if case .interval(let seconds, _) = notification.trigger {
            return seconds
        }
        return 0
    }

    public func triggerDate() -> Int64 {
        if case .date(let milliseconds) = notification.trigger {
            return milliseconds
        }
        return 0
    }

    public func triggerPart(_ index: Int32) -> Int32 {
        guard case .calendar(let parts, _) = notification.trigger else { return -1 }
        let all = [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second, parts.weekday]
        guard all.indices.contains(Int(index)), let value = all[Int(index)] else { return -1 }
        return Int32(clamping: value)
    }

    public func isRemote() -> Bool { notification.isRemote }

    public func delivered() -> Int64 { notification.delivered }
}

/// The built-in `Permissions` contract's view of notifications: the status
/// the presenter last reported, and its prompt with the usual options.
public final class NotificationPermission: PermissionProvider {

    public init() { }

    public func status() -> PermissionStatus {
        HostNotifications.presenter == nil ? .unavailable : HostNotifications.lastStatus
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        guard let presenter = HostNotifications.presenter else {
            completion(.unavailable)
            return
        }
        presenter.requestAuthorization([.alert, .sound, .badge]) { result in
            switch result {
            case .success(let settings):
                HostNotifications.lastStatus = settings.authorizationStatus
                completion(settings.authorizationStatus)
            case .failure:
                completion(HostNotifications.lastStatus)
            }
        }
    }
}

/// The notifications module: both contracts, their records and callbacks.
public enum HostNotificationsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            NotificationsProxy.descriptor, NotificationRecordProxy.descriptor,
            NotificationCallbackProxy.descriptor, NotificationsDelegateProxy.descriptor,
            PushNotificationsProxy.descriptor, PushCallbackProxy.descriptor, PushDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        NotificationsProxy.register(HostNotifications.self, in: registrar)
        NotificationRecordProxy.register(HostNotificationRecord.self, in: registrar)
        NotificationCallbackProxy.registerInterface(in: registrar)
        NotificationsDelegateProxy.registerInterface(in: registrar)
        PushNotificationsProxy.register(HostPushNotifications.self, in: registrar)
        PushCallbackProxy.registerInterface(in: registrar)
        PushDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.notifications: NotificationPermission()]
    }
}
