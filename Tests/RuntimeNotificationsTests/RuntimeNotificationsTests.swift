import Foundation
import Testing
import DynamicNotifications
import DynamicRuntime
import RuntimeHost
import RuntimeNative
@testable import RuntimeNotifications

/// A host's notification centre kept in memory: it holds what's scheduled
/// and the test says when each fires.
final class TestCentre: NotificationPresenter {

    var calls: [String] = []

    var settingsNow = NotificationSettings(authorizationStatus: .notDetermined, deliversWhenClosed: true)

    /// What the user answers when asked.
    var answer: PermissionStatus = .granted

    var prompts = 0

    var categories: [NotificationCategory] = []

    var pendingNotifications: [HostNotification] = []

    var deliveredNotifications: [HostNotification] = []

    var badge = 0

    var limit = 64

    var subscription: PushSubscription?

    func settings(_ completion: @escaping (NotificationSettings) -> Void) {
        completion(settingsNow)
    }

    func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        calls.append("requestAuthorization \(options.rawValue)")
        if settingsNow.authorizationStatus == .notDetermined {
            // Asked once; the answer stands.
            prompts += 1
            settingsNow.authorizationStatus = answer
            settingsNow.alerts = answer == .granted && options.contains(.alert)
            settingsNow.sounds = answer == .granted && options.contains(.sound)
            settingsNow.badges = answer == .granted && options.contains(.badge)
        }
        completion(.success(settingsNow))
    }

    func requestExactTiming(_ completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        calls.append("requestExactTiming")
        settingsNow.exactTiming = true
        completion(.success(settingsNow))
    }

    func setCategories(_ categories: [NotificationCategory]) {
        self.categories = categories
    }

    func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void) {
        pendingNotifications.removeAll { $0.identifier == notification.identifier }
        deliveredNotifications.removeAll { $0.identifier == notification.identifier }
        if notification.trigger == nil {
            deliveredNotifications.append(notification)
        } else {
            guard pendingNotifications.count < limit else {
                completion(.limitReached)
                return
            }
            pendingNotifications.append(notification)
        }
        completion(nil)
    }

    func pending(_ completion: @escaping ([String]) -> Void) {
        completion(pendingNotifications.map(\.identifier))
    }

    func delivered(_ completion: @escaping ([String]) -> Void) {
        completion(deliveredNotifications.map(\.identifier))
    }

    func removePending(_ identifiers: [String]?) {
        pendingNotifications.removeAll { identifiers?.contains($0.identifier) ?? true }
    }

    func removeDelivered(_ identifiers: [String]?) {
        deliveredNotifications.removeAll { identifiers?.contains($0.identifier) ?? true }
    }

    func setBadgeCount(_ count: Int) {
        badge = count
    }

    func setForegroundPresentation(_ options: NotificationPresentationOptions) {
        calls.append("setForegroundPresentation \(options.rawValue)")
    }

    func registerForPush(serverKey: String?, completion: @escaping (Result<PushSubscription, NotificationError>) -> Void) {
        calls.append("registerForPush \(serverKey ?? "-")")
        completion(subscription.map(Result.success) ?? .failure(.unavailable))
    }

    func unregisterForPush(_ completion: @escaping (NotificationError?) -> Void) {
        calls.append("unregisterForPush")
        subscription = nil
        completion(nil)
    }

    /// The time for a scheduled notification has come: the system shows
    /// it, and the app hears if it's running.
    func fire(_ identifier: String) -> HostNotification? {
        guard let index = pendingNotifications.firstIndex(where: { $0.identifier == identifier }) else { return nil }
        let notification = pendingNotifications[index]
        if !(notification.trigger?.repeats ?? false) {
            pendingNotifications.remove(at: index)
        }
        deliveredNotifications.append(notification)
        HostNotifications.received(notification)
        return notification
    }
}

/// A centre that only shows notifications: the defaults a presenter gets.
final class PlainCentre: NotificationPresenter {
    func settings(_ completion: @escaping (NotificationSettings) -> Void) {
        completion(NotificationSettings(authorizationStatus: .granted, alerts: true, exactTiming: true))
    }
    func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        settings { completion(.success($0)) }
    }
    func setCategories(_ categories: [NotificationCategory]) { }
    func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void) { completion(nil) }
    func pending(_ completion: @escaping ([String]) -> Void) { completion([]) }
    func delivered(_ completion: @escaping ([String]) -> Void) { completion([]) }
    func removePending(_ identifiers: [String]?) { }
    func removeDelivered(_ identifiers: [String]?) { }
    func setBadgeCount(_ count: Int) { }
    func setForegroundPresentation(_ options: NotificationPresentationOptions) { }
}

/// `HostNotifications` over a test's notification centre, driven from the
/// guest's `UserNotificationCenter` through the runtime; and the triggers'
/// own arithmetic.
///
/// Serialized: `HostNotifications`, the guest's one centre and the native
/// runtime are shared.
@Suite(.serialized) final class RuntimeNotificationsTests {

    let centre = TestCentre()

    let center = UserNotificationCenter.current

    /// 2026-11-20 10:00:00 UTC, a Friday.
    static let now = Date(timeIntervalSince1970: 1_795_168_800)

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostNotifications.reset()
        HostNotifications.presenter = centre
        HostNotifications.deliver = { $0() }
        HostNotifications.now = { Self.now }
        HostNotificationsModule.register(in: native)
        center.onResponse(nil)
        center.onReceive(nil)
        center.onSubscriptionChange(nil)
    }

    deinit {
        HostNotifications.reset()
    }

    func failure<Value>(_ result: Result<Value, NotificationError>?) -> NotificationError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    func allow() {
        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization { status = $0 }
        #expect(status == .success(.granted))
    }

    @discardableResult
    func add(_ identifier: String, _ content: NotificationContent = NotificationContent(title: "T"), _ trigger: NotificationTrigger? = nil) -> NotificationError? {
        var result: Result<Void, NotificationError>?
        center.add(NotificationRequest(identifier: identifier, content: content, trigger: trigger)) { result = $0 }
        if case .failure(let error) = result { return error }
        return result == nil ? .unknown : nil
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostNotificationsModule.contracts.map(\.name) == [
            "org.pureswift.notifications.Notifications", "org.pureswift.notifications.Record",
            "org.pureswift.notifications.Callback", "org.pureswift.notifications.Delegate",
            "org.pureswift.notifications.Push", "org.pureswift.notifications.PushCallback",
            "org.pureswift.notifications.PushDelegate",
        ])
        #expect(HostNotificationsModule.isUsed(by: ["org.pureswift.notifications.Push"]))
    }

    // MARK: Triggers

    @Test func triggersKnowWhenTheyNextFire() {
        let now = Self.now
        let calendar = Self.utc
        #expect(HostNotificationTrigger.interval(seconds: 300, repeats: false).nextDate(after: now) == now.addingTimeInterval(300))
        #expect(HostNotificationTrigger.interval(seconds: 0, repeats: false).nextDate(after: now) == nil)
        let later = Int64(now.timeIntervalSince1970 * 1000) + 5000
        #expect(HostNotificationTrigger.date(milliseconds: later).nextDate(after: now) == now.addingTimeInterval(5))
        #expect(HostNotificationTrigger.date(milliseconds: later - 10_000).nextDate(after: now) == nil, "it has passed")

        func next(_ parts: HostNotificationDateParts, after: Date = now) -> Date? {
            HostNotificationTrigger.calendar(parts, repeats: true).nextDate(after: after, calendar: calendar)
        }
        // Friday 20 November 2026, 10:00.
        #expect(next(.init(hour: 7, minute: 0)) == date(2026, 11, 21, 7), "seven has gone today")
        #expect(next(.init(hour: 12, minute: 30)) == date(2026, 11, 20, 12, 30))
        #expect(next(.init(hour: 7, minute: 0, weekday: 2)) == date(2026, 11, 23, 7), "Monday")
        #expect(next(.init(hour: 7, minute: 0, weekday: 6)) == date(2026, 11, 27, 7), "Friday's seven has gone: next week's")
        #expect(next(.init(month: 2, day: 29, hour: 9)) == date(2028, 2, 29, 9), "the next leap year")
        #expect(next(.init(year: 2027, month: 1, day: 1, hour: 0, minute: 0)) == date(2027, 1, 1))
        #expect(next(.init(year: 2020, month: 1, day: 1)) == nil, "that year has gone")
        // Repeating: each one from the last.
        let first = next(.init(hour: 7, minute: 0))!
        #expect(next(.init(hour: 7, minute: 0), after: first) == date(2026, 11, 22, 7))
    }

    @Test func aTimeTheClocksSkipIsTheNextTheyShow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // Clocks there go from 2:00 to 3:00 on 14 March 2027.
        let before = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 1)))
        let alarm = HostNotificationTrigger.calendar(.init(hour: 2, minute: 30), repeats: true)
        let fires = try #require(alarm.nextDate(after: before, calendar: calendar))
        #expect(calendar.dateComponents([.day, .hour], from: fires) == DateComponents(day: 14, hour: 3), "not skipped to the day after")
    }

    @Test func calendarPartsAreChecked() {
        #expect(HostNotificationDateParts(hour: 7, minute: 0).isValid)
        #expect(HostNotificationDateParts(month: 2, day: 29).isValid)
        #expect(!HostNotificationDateParts().isValid, "nothing to match")
        #expect(HostNotificationDateParts().isEmpty)
        #expect(!HostNotificationDateParts(month: 2, day: 30).isValid)
        #expect(!HostNotificationDateParts(month: 4, day: 31).isValid)
        #expect(!HostNotificationDateParts(month: 13).isValid && !HostNotificationDateParts(hour: 24).isValid)
        #expect(!HostNotificationDateParts(minute: 60).isValid && !HostNotificationDateParts(weekday: 0).isValid)
        #expect(!HostNotificationDateParts(weekday: 8).isValid)
        #expect(HostNotificationDateParts(hour: 7, weekday: 2).components == DateComponents(hour: 7, weekday: 2))
    }

    @Test func aRequestIsCheckedBeforeItsAdded() {
        let now = Self.now
        func problem(_ trigger: HostNotificationTrigger?, identifier: String = "a") -> NotificationError? {
            HostNotification(identifier: identifier, trigger: trigger).problem(at: now, calendar: Self.utc)
        }
        #expect(problem(nil) == nil)
        #expect(problem(nil, identifier: "") == .invalid, "it needs a name to be replaced or removed by")
        #expect(problem(.interval(seconds: 1, repeats: false)) == nil)
        #expect(problem(.interval(seconds: 0, repeats: false)) == .invalid)
        #expect(problem(.interval(seconds: 59, repeats: true)) == .invalid, "repeating needs a minute")
        #expect(problem(.interval(seconds: 60, repeats: true)) == nil)
        #expect(problem(.date(milliseconds: 1_000)) == .invalid, "a moment that has passed")
        #expect(problem(.date(milliseconds: Int64(now.timeIntervalSince1970 * 1000) + 1)) == nil)
        #expect(problem(.calendar(.init(hour: 7), repeats: true)) == nil)
        #expect(problem(.calendar(.init(month: 2, day: 30), repeats: true)) == .invalid, "no such date")
        #expect(problem(.calendar(.init(year: 2020), repeats: false)) == .invalid)
        #expect(problem(.calendar(.init(), repeats: true)) == .invalid)
    }

    // MARK: Permission

    @Test func nothingIsShownUntilTheUserAllowsIt() {
        var settings: Result<NotificationSettings, NotificationError>?
        center.settings { settings = $0 }
        #expect(try! settings!.get().authorizationStatus == .notDetermined)
        #expect(centre.prompts == 0, "looking never asks")
        #expect(add("early") == .notAuthorized, "where a platform would drop it and say nothing")
        #expect(centre.deliveredNotifications.isEmpty)

        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization([.alert, .sound]) { status = $0 }
        #expect(status == .success(.granted))
        #expect(centre.calls == ["requestAuthorization 3"])
        center.requestAuthorization { status = $0 }
        #expect(centre.prompts == 1, "asked once; the answer stands")

        center.settings { settings = $0 }
        #expect(settings == .success(NotificationSettings(authorizationStatus: .granted, alerts: true, sounds: true,
                                                          badges: false, exactTiming: false, deliversWhenClosed: true)))
        #expect(add("now") == nil)
        #expect(centre.deliveredNotifications.map(\.identifier) == ["now"])

        center.requestExactTiming { settings = $0 }
        #expect(try! settings!.get().exactTiming)
    }

    @Test func aRefusalIsFinal() {
        centre.answer = .denied
        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization { status = $0 }
        #expect(status == .success(.denied))
        centre.answer = .granted
        center.requestAuthorization { status = $0 }
        #expect(status == .success(.denied) && centre.prompts == 1, "no platform asks twice")
        #expect(add("refused") == .notAuthorized)
    }

    @Test func theBuiltInPermissionIsTheSameOne() {
        let provider = HostNotificationsModule.permissionProviders()[.notifications]
        #expect(provider?.status() == .notDetermined)
        var asked: PermissionStatus?
        provider?.request { asked = $0 }
        #expect(asked == .granted && centre.calls == ["requestAuthorization 7"], "with the usual options")
        #expect(provider?.status() == .granted, "the last answer, since this one can't wait")

        // What the user changes in Settings shows once the host looks again.
        centre.settingsNow.authorizationStatus = .denied
        #expect(HostNotifications.lastStatus == .granted)
        HostNotifications.refreshStatus()
        #expect(provider?.status() == .denied)

        HostNotifications.presenter = nil
        #expect(provider?.status() == .unavailable)
    }

    @Test func aHostWithNoCentreSaysSo() {
        HostNotifications.presenter = nil
        var settings: Result<NotificationSettings, NotificationError>?
        center.settings { settings = $0 }
        #expect(try! settings!.get().authorizationStatus == .unavailable)
        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization { status = $0 }
        #expect(status == .success(.unavailable))
        #expect(add("x") == .unsupported)
        var pending: Result<[String], NotificationError>?
        center.pendingIdentifiers { pending = $0 }
        #expect(pending == .success([]))
        HostNotifications.declaresRemote = true
        var subscription: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications { subscription = $0 }
        #expect(failure(subscription) == .unsupported)
    }

    // MARK: Requests

    @Test func aRequestReachesTheCentreAsItWasAsked() {
        allow()
        var content = NotificationContent()
        content.title = "Tea"
        content.subtitle = "Kitchen"
        content.body = "Your timer is done."
        content.categoryIdentifier = "timer"
        content.threadIdentifier = "timers"
        content.badge = 2
        content.isSilent = true
        content.userInfo = ["timer": "42"]
        #expect(add("timer-42", content, .timeInterval(300)) == nil)
        #expect(centre.pendingNotifications == [HostNotification(
            identifier: "timer-42", title: "Tea", subtitle: "Kitchen", body: "Your timer is done.", category: "timer",
            thread: "timers", badge: 2, isSilent: true, userInfo: ["timer": "42"],
            trigger: .interval(seconds: 300, repeats: false)
        )])

        #expect(add("alarm", NotificationContent(title: "Up"), .calendar(hour: 7, minute: 0, weekday: 2, repeats: true)) == nil)
        #expect(centre.pendingNotifications.last?.trigger == .calendar(.init(hour: 7, minute: 0, weekday: 2), repeats: true))
        let moment = Int64(Self.now.timeIntervalSince1970 * 1000) + 60_000
        #expect(add("once", NotificationContent(title: "Once"), .date(millisecondsSince1970: moment)) == nil)
        #expect(centre.pendingNotifications.last?.trigger == .date(milliseconds: moment))
        #expect(centre.pendingNotifications.last?.badge == nil)
    }

    @Test func aRequestThatCantFireIsRefused() {
        allow()
        #expect(add("", NotificationContent(title: "No name")) == .invalid)
        #expect(add("past", NotificationContent(), .date(millisecondsSince1970: 1_000)) == .invalid)
        #expect(add("fast", NotificationContent(), .timeInterval(30, repeats: true)) == .invalid)
        #expect(add("never", NotificationContent(), .calendar(month: 2, day: 30)) == .invalid)
        #expect(add("gone", NotificationContent(), .calendar(year: 2020, month: 1, day: 1)) == .invalid)
        #expect(centre.pendingNotifications.isEmpty && centre.deliveredNotifications.isEmpty)

        centre.limit = 2
        #expect(add("a", NotificationContent(), .timeInterval(10)) == nil)
        #expect(add("b", NotificationContent(), .timeInterval(10)) == nil)
        #expect(add("c", NotificationContent(), .timeInterval(10)) == .limitReached)
        #expect(add("a", NotificationContent(title: "again"), .timeInterval(20)) == nil, "replacing one isn't one more")
        #expect(centre.pendingNotifications.map(\.title) == ["", "again"])
    }

    @Test func pendingAndDeliveredAreListedAndRemoved() {
        allow()
        add("a", NotificationContent(), .timeInterval(10))
        add("b", NotificationContent(), .timeInterval(10))
        add("c", NotificationContent(), .timeInterval(10))
        add("shown")
        var pending: Result<[String], NotificationError>?
        center.pendingIdentifiers { pending = $0 }
        #expect(pending == .success(["a", "b", "c"]))
        var delivered: Result<[String], NotificationError>?
        center.deliveredIdentifiers { delivered = $0 }
        #expect(delivered == .success(["shown"]))

        center.removePending(["b"])
        center.removePending([])
        center.pendingIdentifiers { pending = $0 }
        #expect(pending == .success(["a", "c"]), "removing none removes none")
        center.removeAllPending()
        center.removeDelivered(["shown"])
        #expect(centre.pendingNotifications.isEmpty && centre.deliveredNotifications.isEmpty)
        add("x")
        add("y")
        center.removeAllDelivered()
        #expect(centre.deliveredNotifications.isEmpty)

        center.setBadgeCount(5)
        #expect(centre.badge == 5)
        center.foregroundPresentation = [.list]
        #expect(centre.calls.last == "setForegroundPresentation 2")
        center.foregroundPresentation = .all
    }

    @Test func categoriesReachTheCentreTogether() {
        let timer = NotificationCategory(
            identifier: "timer", name: "Timers",
            actions: [
                NotificationAction(identifier: "repeat", title: "Repeat"),
                NotificationAction(identifier: "stop", title: "Stop", options: .destructive),
                NotificationAction(identifier: "", title: "Nameless"),
            ],
            interruption: .timeSensitive, sound: .named("chime.wav"))
        let message = NotificationCategory(
            identifier: "message", name: "Messages",
            actions: [.textInput(identifier: "reply", title: "Reply", buttonTitle: "Send", placeholder: "Message")],
            sound: .none)
        center.setCategories([timer, message, NotificationCategory(identifier: "timer", name: "Twice")])
        var expected = timer
        expected.actions.removeLast()
        #expect(centre.categories == [expected, message], "a button with no identifier, and a second category of one name, are dropped")

        center.setCategories([message])
        #expect(centre.categories == [message], "they replace those before")
        center.setCategories([])
        #expect(centre.categories.isEmpty)
    }

    // MARK: Delivery

    @Test func aNotificationThatFiresWhileTheAppRunsIsReported() {
        allow()
        var received: [DeliveredNotification] = []
        center.onReceive { received.append($0) }
        add("timer-1", NotificationContent(title: "Tea", userInfo: ["timer": "1"]), .timeInterval(300))
        add("daily", NotificationContent(title: "Daily"), .calendar(hour: 7, repeats: true))
        #expect(centre.fire("timer-1") != nil)
        #expect(received.map(\.identifier) == ["timer-1"])
        #expect(received[0].content.title == "Tea" && received[0].userInfo == ["timer": "1"])
        #expect(received[0].date == Int64(Self.now.timeIntervalSince1970 * 1000), "stamped when the host didn't say")
        #expect(!received[0].isRemote)
        #expect(centre.pendingNotifications.map(\.identifier) == ["daily"])
        #expect(centre.fire("daily") != nil)
        #expect(centre.pendingNotifications.map(\.identifier) == ["daily"], "one that repeats stays scheduled")

        HostNotifications.received(HostNotification(identifier: "push-1", title: "Ada", userInfo: ["chat": "7"], isRemote: true, delivered: 5))
        #expect(received.last?.isRemote == true && received.last?.date == 5)

        center.onReceive(nil)
        HostNotifications.received(HostNotification(identifier: "unheard"))
        #expect(received.count == 3, "dropped when nothing listens")
    }

    @Test func theResponseThatStartedTheAppWaitsForIt() {
        // The user tapped a notification, and the system launched the app.
        HostNotifications.responded(to: HostNotification(identifier: "timer-1", title: "Tea", category: "timer", userInfo: ["timer": "1"]))
        HostNotifications.responded(to: HostNotification(identifier: "msg-1", title: "Ada", isRemote: true), action: "reply", text: "On my way")

        var responses: [NotificationResponse] = []
        center.onResponse { responses.append($0) }
        #expect(responses.count == 2, "at once, in order")
        #expect(responses[0].actionIdentifier == NotificationAction.defaultIdentifier)
        #expect(responses[0].notification.content.categoryIdentifier == "timer")
        #expect(responses[0].notification.userInfo == ["timer": "1"])
        #expect(responses[1].actionIdentifier == "reply" && responses[1].text == "On my way")
        #expect(responses[1].notification.isRemote)

        HostNotifications.responded(to: HostNotification(identifier: "timer-2"), action: "stop")
        #expect(responses.count == 3 && responses[2].actionIdentifier == "stop", "and as they happen while it listens")

        center.onResponse(nil)
        HostNotifications.responded(to: HostNotification(identifier: "timer-3"))
        #expect(responses.count == 3)
        center.onResponse { responses.append($0) }
        #expect(responses.last?.notification.identifier == "timer-3", "kept while nothing listened")
        center.onResponse(nil)
    }

    // MARK: Push

    @Test func pushNeedsTheManifestToDeclareIt() {
        centre.subscription = PushSubscription(service: .apns, address: "a1b2", isDevelopment: true)
        var result: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications { result = $0 }
        #expect(failure(result) == .notDeclared)
        #expect(centre.calls.isEmpty, "the push service is never asked")
        var unregistered: Result<Void, NotificationError>?
        center.unregisterForRemoteNotifications { unregistered = $0 }
        #expect(failure(unregistered) == .notDeclared)

        HostNotifications.declaresRemote = true
        center.registerForRemoteNotifications(applicationServerKey: "BEl62i") { result = $0 }
        #expect(centre.calls == ["registerForPush BEl62i"])
        #expect(result == .success(PushSubscription(service: .apns, address: "a1b2", isDevelopment: true)))

        var changes: [PushSubscription] = []
        center.onSubscriptionChange { changes.append($0) }
        let renewed = PushSubscription(service: .webPush, address: "https://push.example/2", publicKey: "p256", authSecret: "auth")
        HostNotifications.pushSubscriptionChanged(renewed)
        #expect(changes == [renewed])
        center.onSubscriptionChange(nil)
        HostNotifications.pushSubscriptionChanged(renewed)
        #expect(changes.count == 1)

        center.unregisterForRemoteNotifications { unregistered = $0 }
        #expect((try? unregistered?.get()) != nil)
        center.registerForRemoteNotifications { result = $0 }
        #expect(failure(result) == .unavailable, "the service can't be reached now")
    }

    @Test func aCentreWithNoPushServiceSaysSo() {
        HostNotifications.presenter = PlainCentre()
        HostNotifications.declaresRemote = true
        var result: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications { result = $0 }
        #expect(failure(result) == .unsupported)
        var settings: Result<NotificationSettings, NotificationError>?
        center.requestExactTiming { settings = $0 }
        #expect(try! settings!.get().exactTiming, "timing is exact already, or not the user's to change")
        #expect(add("plain") == nil)
    }

    /// The configuration a host uses: answers on the main dispatch queue,
    /// after the call that asked has returned.
    @MainActor @Test func aGuestAwaitsTheHostsCentre() async throws {
        HostNotifications.deliver = { DispatchQueue.main.async(execute: $0) }
        let center = self.center
        #expect(try await center.settings().authorizationStatus == .notDetermined)
        #expect(try await center.requestAuthorization() == .granted)
        try await center.add(NotificationRequest(identifier: "a", content: NotificationContent(title: "A"), trigger: .timeInterval(60)))
        #expect(try await center.pendingIdentifiers() == ["a"])
        #expect(try await center.deliveredIdentifiers() == [])
        do {
            try await center.add(NotificationRequest(identifier: "b", content: NotificationContent(), trigger: .timeInterval(-1)))
            Issue.record("an interval that has passed")
        } catch {
            #expect(error == .invalid)
        }
        do {
            _ = try await center.registerForRemoteNotifications()
            Issue.record("the manifest doesn't declare push")
        } catch {
            #expect(error == .notDeclared)
        }
    }
}
