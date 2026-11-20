import Testing
import DynamicNotifications
import DynamicRuntime
import RuntimeNative

/// A record that writes down what it's told, and answers what it was given.
final class ScriptedRecord: NotificationRecord {

    let id: String
    var titleValue = ""
    var subtitleValue = ""
    var bodyValue = ""
    var categoryValue: String?
    var threadValue: String?
    var badgeValue: Int32 = -1
    var silent = false
    var values: [String: String] = [:]
    var remote = false
    var deliveredAt: Int64 = 0

    init(_ id: String) {
        self.id = id
    }

    /// One the host delivered.
    convenience init(_ id: String, title: String, values: [String: String] = [:], category: String? = nil, remote: Bool = false, deliveredAt: Int64 = 0) {
        self.init(id)
        self.titleValue = title
        self.values = values
        self.categoryValue = category
        self.remote = remote
        self.deliveredAt = deliveredAt
    }

    static func make(_ identifier: String) -> ScriptedRecord { ScriptedRecord(identifier) }

    func identifier() -> String { id }
    func setTitle(_ title: String) { titleValue = title }
    func title() -> String { titleValue }
    func setSubtitle(_ subtitle: String) { subtitleValue = subtitle }
    func subtitle() -> String { subtitleValue }
    func setBody(_ body: String) { bodyValue = body }
    func body() -> String { bodyValue }
    func setCategory(_ identifier: String?) { categoryValue = identifier }
    func category() -> String? { categoryValue }
    func setThread(_ identifier: String?) { threadValue = identifier }
    func thread() -> String? { threadValue }
    func setBadge(_ count: Int32) { badgeValue = count }
    func badge() -> Int32 { badgeValue }
    func setSilent(_ silent: Bool) { self.silent = silent }
    func isSilent() -> Bool { silent }
    func setValue(_ value: String?, forKey key: String) { values[key] = value }
    func keys() -> [String] { values.keys.sorted() }
    func value(_ key: String) -> String? { values[key] }
    func setInterval(_ seconds: Double, repeats: Bool) {
        kind = 1
        interval = seconds
        repeating = repeats
    }
    func setDate(_ milliseconds: Int64) {
        kind = 2
        date = milliseconds
    }
    func setCalendar(_ year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32, repeats: Bool) {
        kind = 3
        parts = [year, month, day, hour, minute, second, weekday]
        repeating = repeats
    }
    func isRemote() -> Bool { remote }
    func delivered() -> Int64 { deliveredAt }

    // The trigger as the host reads it back.
    var kind: Int32 = 0
    var repeating = false
    var interval: Double = 0
    var date: Int64 = 0
    var parts: [Int32] = []
    func triggerKind() -> Int32 { kind }
    func triggerRepeats() -> Bool { repeating }
    func triggerInterval() -> Double { interval }
    func triggerDate() -> Int64 { date }
    func triggerPart(_ index: Int32) -> Int32 { parts.indices.contains(Int(index)) ? parts[Int(index)] : -1 }
}

/// Everything a record says, on one line, read as a host reads it: through
/// the contract, since what the guest hands back is its proxy.
func triggerSummary(of record: any NotificationRecord) -> String {
    switch record.triggerKind() {
    case 1: "interval \(record.triggerInterval()) \(record.triggerRepeats())"
    case 2: "date \(record.triggerDate())"
    case 3: "calendar " + (0..<7).map { String(record.triggerPart(Int32($0))) }.joined(separator: " ") + " \(record.triggerRepeats())"
    default: "now"
    }
}

func summary(of record: any NotificationRecord) -> String {
    let pairs = record.keys().map { "\($0)=\(record.value($0) ?? "?")" }.joined(separator: ",")
    let trigger = triggerSummary(of: record)
    return "\(record.identifier()): \(record.title())|\(record.subtitle())|\(record.body()) category=\(record.category() ?? "-") "
        + "thread=\(record.thread() ?? "-") badge=\(record.badge()) silent=\(record.isSilent()) [\(pairs)] \(trigger)"
}

/// A host's notifications that only write down what they're asked, and
/// keep each callback for the test to answer.
final class ScriptedNotifications: Notifications {

    nonisolated(unsafe) static var instance = ScriptedNotifications()

    var calls: [String] = []

    var callbacks: [any NotificationCallback] = []

    /// The trigger of each notification added.
    var triggers: [String] = []

    /// The categories being set.
    var categories: [String] = []

    var delegate: (any NotificationsDelegate)?

    static func current() -> ScriptedNotifications { instance }

    func callback(_ back: Int = 0) -> any NotificationCallback {
        callbacks[callbacks.count - 1 - back]
    }

    func settings(_ callback: any NotificationCallback) {
        calls.append("settings")
        callbacks.append(callback)
    }

    func requestAuthorization(_ options: Int32, callback: any NotificationCallback) {
        calls.append("requestAuthorization \(options)")
        callbacks.append(callback)
    }

    func requestExactTiming(_ callback: any NotificationCallback) {
        calls.append("requestExactTiming")
        callbacks.append(callback)
    }

    func beginCategories() {
        categories = []
    }

    func addCategory(_ identifier: String, name: String, interruption: Int32, sound: Int32, soundName: String?) {
        categories.append("\(identifier) \"\(name)\" interruption=\(interruption) sound=\(sound):\(soundName ?? "-")")
    }

    func addAction(_ category: String, identifier: String, title: String, options: Int32) {
        categories.append("\(category)[\(identifier) \(title) \(options)]")
    }

    func addTextAction(_ category: String, identifier: String, title: String, options: Int32, buttonTitle: String, placeholder: String) {
        categories.append("\(category)[\(identifier) \(title) \(options) text:\(buttonTitle)/\(placeholder)]")
    }

    func endCategories() {
        calls.append("setCategories " + categories.joined(separator: "; "))
    }

    func add(_ notification: any NotificationRecord, callback: any NotificationCallback) {
        calls.append("add " + summary(of: notification))
        triggers.append(triggerSummary(of: notification))
        callbacks.append(callback)
    }

    func pending(_ callback: any NotificationCallback) {
        calls.append("pending")
        callbacks.append(callback)
    }

    func delivered(_ callback: any NotificationCallback) {
        calls.append("delivered")
        callbacks.append(callback)
    }

    func removePending(_ identifiers: [String]) { calls.append("removePending \(identifiers)") }
    func removeAllPending() { calls.append("removeAllPending") }
    func removeDelivered(_ identifiers: [String]) { calls.append("removeDelivered \(identifiers)") }
    func removeAllDelivered() { calls.append("removeAllDelivered") }
    func setBadgeCount(_ count: Int32) { calls.append("setBadgeCount \(count)") }
    func setForegroundPresentation(_ options: Int32) { calls.append("setForegroundPresentation \(options)") }

    func setDelegate(_ delegate: (any NotificationsDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }
}

final class ScriptedPush: PushNotifications {

    nonisolated(unsafe) static var instance = ScriptedPush()

    var calls: [String] = []

    var callbacks: [any PushCallback] = []

    var delegate: (any PushDelegate)?

    static func shared() -> ScriptedPush { instance }

    func register(_ serverKey: String?, callback: any PushCallback) {
        calls.append("register \(serverKey ?? "-")")
        callbacks.append(callback)
    }

    func unregister(_ callback: any PushCallback) {
        calls.append("unregister")
        callbacks.append(callback)
    }

    func setDelegate(_ delegate: (any PushDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }
}

/// Serialized: the tests share the native runtime, the scripted host and
/// the guest's one notification centre.
@Suite(.serialized) struct DynamicNotificationsTests {

    let host: ScriptedNotifications

    let push: ScriptedPush

    let center = UserNotificationCenter.current

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        NotificationsProxy.register(ScriptedNotifications.self, in: native)
        NotificationRecordProxy.register(ScriptedRecord.self, in: native)
        NotificationCallbackProxy.registerInterface(in: native)
        NotificationsDelegateProxy.registerInterface(in: native)
        PushNotificationsProxy.register(ScriptedPush.self, in: native)
        PushCallbackProxy.registerInterface(in: native)
        PushDelegateProxy.registerInterface(in: native)
        // The centre keeps the host's objects it first asked for, so the
        // scripted ones are emptied, not replaced.
        host = ScriptedNotifications.instance
        push = ScriptedPush.instance
        center.onResponse(nil)
        center.onReceive(nil)
        center.onSubscriptionChange(nil)
        host.calls = []
        host.callbacks = []
        host.triggers = []
        push.calls = []
        push.callbacks = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func failure<Value>(_ result: Result<Value, NotificationError>?) -> NotificationError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: Contracts

    @Test func bothContractsRequireNotifications() {
        let notifications = NotificationsProxy.descriptor
        #expect(notifications.name == "org.pureswift.notifications.Notifications")
        #expect(notifications.capability == .notifications)
        #expect(method(notifications, "current")?.kind == .constructor)
        #expect(method(notifications, "settings:")?.signature == Signature("(O)V"))
        #expect(method(notifications, "requestAuthorization:callback:")?.signature == Signature("(IO)V"))
        #expect(method(notifications, "addCategory:name:interruption:sound:soundName:")?.signature == Signature("(OOIIO)V"))
        #expect(method(notifications, "addTextAction:identifier:title:options:buttonTitle:placeholder:")?.signature == Signature("(OOOIOO)V"))
        #expect(method(notifications, "add:callback:")?.signature == Signature("(OO)V"))
        #expect(method(notifications, "removePending:")?.signature == Signature("(O)V"))
        #expect(method(notifications, "setBadgeCount:")?.signature == Signature("(I)V"))
        #expect(method(notifications, "setDelegate:")?.signature == Signature("(O)V"))
        #expect(notifications.methods.count == 19)

        let push = PushNotificationsProxy.descriptor
        #expect(push.name == "org.pureswift.notifications.Push", "its own contract, so an app's list says whether it uses push")
        #expect(push.capability == .notifications)
        #expect(method(push, "register:callback:")?.signature == Signature("(OO)V"))
        #expect(push.methods.count == 4)
    }

    @Test func recordsAndCallbacksHaveTheirShapes() {
        let record = NotificationRecordProxy.descriptor
        #expect(record.name == "org.pureswift.notifications.Record")
        #expect(record.capability == nil)
        #expect(method(record, "make:")?.kind == .constructor)
        #expect(method(record, "setValue:forKey:")?.signature == Signature("(OO)V"))
        #expect(method(record, "setInterval:repeats:")?.signature == Signature("(DZ)V"))
        #expect(method(record, "setDate:")?.signature == Signature("(J)V"))
        #expect(method(record, "setCalendar:month:day:hour:minute:second:weekday:repeats:")?.signature == Signature("(IIIIIIIZ)V"))
        #expect(method(record, "delivered")?.signature == Signature("()J"))

        #expect(method(record, "triggerPart:")?.signature == Signature("(I)I"))

        let callback = NotificationCallbackProxy.descriptor
        #expect(callback.kind == .callback)
        #expect(method(callback, "didGetSettings:enabled:")?.signature == Signature("(II)V"))
        #expect(method(callback, "didList:")?.signature == Signature("(O)V"))
        let delegate = NotificationsDelegateProxy.descriptor
        #expect(method(delegate, "didRespond:action:text:")?.signature == Signature("(OOO)V"))
        let pushCallback = PushCallbackProxy.descriptor
        #expect(method(pushCallback, "didRegister:address:publicKey:authSecret:development:")?.signature == Signature("(IOOOZ)V"))

        let descriptors = [NotificationsProxy.descriptor, record, callback, delegate,
                           PushNotificationsProxy.descriptor, pushCallback, PushDelegateProxy.descriptor]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Permission

    @Test func settingsSayWhereThePermissionStands() {
        var settings: Result<NotificationSettings, NotificationError>?
        center.settings { settings = $0 }
        #expect(host.calls == ["settings"])
        host.callback().didGetSettings(PermissionStatus.granted.rawValue, enabled: 1 | 2 | 8 | 16)
        #expect(settings == .success(NotificationSettings(authorizationStatus: .granted, alerts: true, sounds: true,
                                                          badges: false, exactTiming: true, deliversWhenClosed: true)))
        #expect(try! settings!.get().isAuthorized)
        #expect(try! settings!.get().enabledBits == 27)

        center.settings { settings = $0 }
        host.callback().didGetSettings(PermissionStatus.limited.rawValue, enabled: 0)
        #expect(try! settings!.get().isAuthorized, "quiet delivery still shows")
        center.settings { settings = $0 }
        host.callback().didGetSettings(PermissionStatus.denied.rawValue, enabled: 0)
        #expect(!(try! settings!.get().isAuthorized))
        center.settings { settings = $0 }
        host.callback().didGetSettings(99, enabled: 0)
        #expect(try! settings!.get().authorizationStatus == .unavailable, "a status from a newer host can't be used")
    }

    @Test func askingPassesWhatTheAppMeansToUse() {
        var status: Result<PermissionStatus, NotificationError>?
        center.requestAuthorization { status = $0 }
        #expect(host.calls == ["requestAuthorization 7"], "alerts, sounds and badges, unless it says")
        host.callback().didGetSettings(PermissionStatus.granted.rawValue, enabled: 7)
        #expect(status == .success(.granted))

        center.requestAuthorization([.alert, .provisional]) { status = $0 }
        #expect(host.calls.last == "requestAuthorization 9")
        host.callback().didGetSettings(PermissionStatus.limited.rawValue, enabled: 1)
        #expect(status == .success(.limited))

        center.requestAuthorization { status = $0 }
        host.callback().didFail(NotificationError.notAllowed.rawValue)
        #expect(failure(status) == .notAllowed, "a browser, outside a user action")

        var settings: Result<NotificationSettings, NotificationError>?
        center.requestExactTiming { settings = $0 }
        #expect(host.calls.last == "requestExactTiming")
        host.callback().didGetSettings(PermissionStatus.granted.rawValue, enabled: 8)
        #expect(try! settings!.get().exactTiming)
    }

    // MARK: Requests

    @Test func aRequestIsWrittenIntoARecord() {
        var content = NotificationContent()
        content.title = "Tea"
        content.subtitle = "Kitchen"
        content.body = "Your timer is done."
        content.categoryIdentifier = "timer"
        content.threadIdentifier = "timers"
        content.badge = 3
        content.isSilent = true
        content.userInfo = ["timer": "42", "kind": "tea"]
        var result: Result<Void, NotificationError>?
        center.add(NotificationRequest(identifier: "timer-42", content: content, trigger: .timeInterval(300))) { result = $0 }
        #expect(host.calls == [
            "add timer-42: Tea|Kitchen|Your timer is done. category=timer thread=timers badge=3 silent=true [kind=tea,timer=42] interval 300.0 false",
        ])
        #expect(result == nil, "nothing until the host answers")
        host.callback().didComplete()
        #expect((try? result?.get()) != nil)

        center.add(NotificationRequest(identifier: "now", content: NotificationContent(title: "Done"))) { result = $0 }
        #expect(host.calls.last == "add now: Done|| category=- thread=- badge=-1 silent=false [] now")
        host.callback().didFail(NotificationError.notAuthorized.rawValue)
        #expect(failure(result) == .notAuthorized)

        // An answer of the wrong kind is a failure, and only the first counts.
        center.add(NotificationRequest(identifier: "odd", content: NotificationContent())) { result = $0 }
        host.callback().didList(["x"])
        host.callback().didComplete()
        #expect(failure(result) == .unknown)
        center.add(NotificationRequest(identifier: "new", content: NotificationContent())) { result = $0 }
        host.callback().didFail(77)
        #expect(failure(result) == .unknown, "an error from a newer host")
    }

    @Test func triggersSayWhen() {
        func trigger(_ trigger: NotificationTrigger) -> String {
            center.add(NotificationRequest(identifier: "t", content: NotificationContent(), trigger: trigger)) { _ in }
            return host.triggers.last ?? "?"
        }
        #expect(trigger(.timeInterval(90, repeats: true)) == "interval 90.0 true")
        #expect(trigger(.date(millisecondsSince1970: 1_800_000_000_000)) == "date 1800000000000")
        #expect(trigger(.calendar(hour: 7, minute: 0, repeats: true)) == "calendar -1 -1 -1 7 0 -1 -1 true", "every morning")
        #expect(trigger(.calendar(hour: 7, minute: 30, weekday: 2, repeats: true)) == "calendar -1 -1 -1 7 30 -1 2 true")
        #expect(trigger(.calendar(year: 2027, month: 1, day: 1, hour: 0, minute: 0, second: 0)) == "calendar 2027 1 1 0 0 0 -1 false")
        #expect(NotificationTrigger.timeInterval(60).repeats == false)
        #expect(NotificationTrigger.calendar(hour: 7) == .calendar(hour: 7) && NotificationTrigger.calendar(hour: 7) != .calendar(hour: 8))
    }

    @Test func categoriesCarryButtonsAndBehaviour() {
        center.setCategories([
            NotificationCategory(
                identifier: "timer", name: "Timers",
                actions: [
                    NotificationAction(identifier: "repeat", title: "Repeat"),
                    NotificationAction(identifier: "stop", title: "Stop", options: [.destructive, .authenticationRequired]),
                ],
                interruption: .timeSensitive, sound: .named("chime.wav")),
            NotificationCategory(
                identifier: "message", name: "Messages",
                actions: [.textInput(identifier: "reply", title: "Reply", buttonTitle: "Send", placeholder: "Message")],
                sound: .none),
            NotificationCategory(identifier: "news", name: "News", interruption: .passive),
        ])
        #expect(host.calls == [
            #"setCategories timer "Timers" interruption=2 sound=2:chime.wav; timer[repeat Repeat 0]; timer[stop Stop 3]; "#
                + #"message "Messages" interruption=1 sound=1:-; message[reply Reply 0 text:Send/Message]; "#
                + #"news "News" interruption=0 sound=0:-"#,
        ])
        #expect(NotificationAction.defaultIdentifier.isEmpty)
    }

    @Test func pendingAndDeliveredAreListedAndRemoved() {
        var pending: Result<[String], NotificationError>?
        center.pendingIdentifiers { pending = $0 }
        host.callback().didList(["timer-1", "timer-2"])
        #expect(pending == .success(["timer-1", "timer-2"]))
        var delivered: Result<[String], NotificationError>?
        center.deliveredIdentifiers { delivered = $0 }
        host.callback().didList([])
        #expect(delivered == .success([]))

        host.calls = []
        center.removePending(["timer-1"])
        center.removePending([])
        center.removeAllPending()
        center.removeDelivered(["a", "b"])
        center.removeDelivered([])
        center.removeAllDelivered()
        center.setBadgeCount(4)
        center.setBadgeCount(-2)
        #expect(host.calls == [
            #"removePending ["timer-1"]"#, "removeAllPending", #"removeDelivered ["a", "b"]"#, "removeAllDelivered",
            "setBadgeCount 4", "setBadgeCount 0",
        ], "removing none removes none, and never all")
    }

    @Test func theAppSaysHowOneIsShownWhileItsInFront() {
        center.foregroundPresentation = []
        center.foregroundPresentation = [.banner, .sound]
        center.foregroundPresentation = .all
        #expect(host.calls == ["setForegroundPresentation 0", "setForegroundPresentation 5", "setForegroundPresentation 15"])
    }

    // MARK: Delivery

    @Test func whatTheUserDidReachesTheHandler() {
        var responses: [NotificationResponse] = []
        center.onResponse { responses.append($0) }
        #expect(host.calls == ["setDelegate"])
        host.delegate?.didRespond(ScriptedRecord("timer-42", title: "Tea", values: ["timer": "42"], category: "timer", deliveredAt: 1_700_000_000_000),
                                  action: "", text: nil)
        host.delegate?.didRespond(ScriptedRecord("msg-1", title: "Ada", remote: true), action: "reply", text: "On my way")
        #expect(responses.count == 2)
        #expect(responses[0].actionIdentifier == NotificationAction.defaultIdentifier, "a tap on the notification itself")
        #expect(responses[0].notification.identifier == "timer-42")
        #expect(responses[0].notification.content.title == "Tea")
        #expect(responses[0].notification.content.categoryIdentifier == "timer")
        #expect(responses[0].notification.userInfo == ["timer": "42"])
        #expect(responses[0].notification.date == 1_700_000_000_000 && !responses[0].notification.isRemote)
        #expect(responses[0].notification.content.badge == nil)
        #expect(responses[1].actionIdentifier == "reply" && responses[1].text == "On my way")
        #expect(responses[1].notification.isRemote && responses[1].notification.date == nil)

        center.onResponse(nil)
        #expect(host.calls == ["setDelegate", "setDelegate nil"], "the host keeps what arrives from here")
    }

    @Test func deliveriesAndResponsesShareOneDelegate() {
        var received: [String] = []
        center.onReceive { received.append($0.identifier) }
        #expect(host.calls == ["setDelegate"])
        host.delegate?.didReceive(ScriptedRecord("a", title: "A"))
        #expect(received == ["a"])

        // A response with nobody to hear it waits for whoever asks.
        host.delegate?.didRespond(ScriptedRecord("b", title: "B"), action: "open", text: nil)
        var responses: [String] = []
        center.onResponse { responses.append("\($0.notification.identifier):\($0.actionIdentifier)") }
        #expect(responses == ["b:open"])
        #expect(host.calls == ["setDelegate"], "still the one delegate")

        center.onReceive(nil)
        #expect(host.calls == ["setDelegate"], "responses are still wanted")
        host.delegate?.didReceive(ScriptedRecord("c", title: "C"))
        #expect(received == ["a"])
        center.onResponse(nil)
        #expect(host.calls == ["setDelegate", "setDelegate nil"])
    }

    // MARK: Push

    @Test func registeringGivesAnAddressForTheServer() {
        var result: Result<PushSubscription, NotificationError>?
        center.registerForRemoteNotifications(applicationServerKey: "BEl62i") { result = $0 }
        #expect(push.calls == ["register BEl62i"])
        push.callbacks[0].didRegister(PushService.webPush.rawValue, address: "https://push.example/abc", publicKey: "p256", authSecret: "auth", development: false)
        #expect(result == .success(PushSubscription(service: .webPush, address: "https://push.example/abc", publicKey: "p256", authSecret: "auth")))

        center.registerForRemoteNotifications { result = $0 }
        #expect(push.calls.last == "register -")
        push.callbacks[1].didRegister(PushService.apns.rawValue, address: "a1b2c3", publicKey: nil, authSecret: nil, development: true)
        #expect(result == .success(PushSubscription(service: .apns, address: "a1b2c3", isDevelopment: true)))

        center.registerForRemoteNotifications { result = $0 }
        push.callbacks[2].didRegister(7, address: "x", publicKey: nil, authSecret: nil, development: false)
        #expect(try! result!.get().service == PushService(rawValue: 7), "a service from a newer host is passed on")

        center.registerForRemoteNotifications { result = $0 }
        push.callbacks[3].didFail(NotificationError.notDeclared.rawValue)
        #expect(failure(result) == .notDeclared)

        var unregistered: Result<Void, NotificationError>?
        center.unregisterForRemoteNotifications { unregistered = $0 }
        push.callbacks[4].didComplete()
        #expect((try? unregistered?.get()) != nil)
        center.unregisterForRemoteNotifications { unregistered = $0 }
        push.callbacks[5].didRegister(0, address: "", publicKey: nil, authSecret: nil, development: false)
        #expect(failure(unregistered) == .unknown)
    }

    @Test func aChangedAddressIsReported() {
        var changes: [PushSubscription] = []
        center.onSubscriptionChange { changes.append($0) }
        #expect(push.calls == ["setDelegate"])
        push.delegate?.didChangeRegistration(PushService.fcm.rawValue, address: "token-2", publicKey: nil, authSecret: nil, development: false)
        #expect(changes == [PushSubscription(service: .fcm, address: "token-2")])
        center.onSubscriptionChange(nil)
        #expect(push.calls == ["setDelegate", "setDelegate nil"])
    }

    // MARK: Async

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded (§6.4), and so is the native runtime.

    @MainActor @Test func callsCanBeAwaited() async throws {
        let host = self.host
        let push = self.push
        let center = self.center
        let asking = Task { @MainActor in
            try await center.requestAuthorization([.alert])
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        host.callback().didGetSettings(PermissionStatus.granted.rawValue, enabled: 1)
        #expect(try await asking.value == .granted)

        let adding = Task { @MainActor in
            try await center.add(NotificationRequest(identifier: "a", content: NotificationContent(title: "A"), trigger: .timeInterval(5)))
            return try await center.pendingIdentifiers()
        }
        while host.callbacks.count < 2 {
            await Task.yield()
        }
        host.callback().didComplete()
        while host.callbacks.count < 3 {
            await Task.yield()
        }
        host.callback().didList(["a"])
        #expect(try await adding.value == ["a"])

        let registering = Task { @MainActor in
            try await center.registerForRemoteNotifications()
        }
        while push.callbacks.isEmpty {
            await Task.yield()
        }
        push.callbacks[0].didRegister(PushService.fcm.rawValue, address: "token", publicKey: nil, authSecret: nil, development: false)
        #expect(try await registering.value.address == "token")

        let refused = Task { @MainActor in
            try await center.settings()
        }
        while host.callbacks.count < 4 {
            await Task.yield()
        }
        host.callback().didFail(NotificationError.unsupported.rawValue)
        var failure: NotificationError?
        do {
            _ = try await refused.value
        } catch {
            failure = error as? NotificationError
        }
        #expect(failure == .unsupported)
    }

    @MainActor @Test func responsesAndDeliveriesAreStreams() async {
        let host = self.host
        let center = self.center
        let responding = Task { @MainActor in
            var actions: [String] = []
            for await response in center.responses {
                actions.append(response.actionIdentifier)
                if actions.count == 2 { break }
            }
            return actions
        }
        while host.delegate == nil {
            await Task.yield()
        }
        host.delegate?.didRespond(ScriptedRecord("a", title: "A"), action: "", text: nil)
        host.delegate?.didRespond(ScriptedRecord("a", title: "A"), action: "stop", text: nil)
        #expect(await responding.value == ["", "stop"])
        #expect(host.calls.last == "setDelegate nil", "a stream that's finished with stops listening")

        let receiving = Task { @MainActor in
            for await notification in center.received {
                return notification.identifier
            }
            return ""
        }
        while host.delegate == nil {
            await Task.yield()
        }
        host.delegate?.didReceive(ScriptedRecord("b", title: "B"))
        #expect(await receiving.value == "b")
    }

    @MainActor @Test func aCancelledTaskStopsWaiting() async {
        let host = self.host
        let center = self.center
        let task = Task { @MainActor in
            try await center.pendingIdentifiers()
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        task.cancel()
        var failure: NotificationError?
        do {
            _ = try await task.value
        } catch {
            failure = error as? NotificationError
        }
        #expect(failure == .cancelled)
        // The host's late answer has nowhere to go, and nothing breaks.
        host.callback().didList(["late"])
    }
}
