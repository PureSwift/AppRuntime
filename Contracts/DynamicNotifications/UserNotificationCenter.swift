import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The app's notifications: `UNUserNotificationCenter`, for a guest.
///
/// ```swift
/// let center = UserNotificationCenter.current
/// let status = try await center.requestAuthorization([.alert, .sound])
/// var content = NotificationContent()
/// content.title = "Tea"
/// content.body = "Your timer is done."
/// try await center.add(NotificationRequest(identifier: "tea", content: content, trigger: .timeInterval(300)))
/// for await response in center.responses { … }
/// ```
///
/// The system shows a notification, with the app open or closed. What
/// differs from Apple's: sound, importance and buttons are a category's,
/// since Android's users set them per channel; and `userInfo` holds
/// strings.
///
/// Each call has a completion-handler form, for code that isn't `async`
/// and for slices built without the concurrency runtime.
///
/// It's guest-side only, over the `Notifications` and `PushNotifications`
/// contracts. The guest is single-threaded (§6.4).
public final class UserNotificationCenter: @unchecked Sendable {

    public static let current = UserNotificationCenter()

    /// The host's notifications, made when first used.
    private var made: (any Notifications)?

    private var madePush: (any PushNotifications)?

    let events = NotificationEvents()

    let pushEvents = PushEvents()

    init() { }

    private var notifications: any Notifications {
        if let made {
            return made
        }
        let notifications = NotificationsProxy.current()
        made = notifications
        return notifications
    }

    private var push: any PushNotifications {
        if let madePush {
            return madePush
        }
        let push = PushNotificationsProxy.shared()
        madePush = push
        return push
    }

    // MARK: Permission

    /// Where the user's permission stands. Never prompts.
    public func settings(completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        notifications.settings(Receiver.settings(completion))
    }

    /// Asks the user, the first time; answers the same without asking
    /// after that. Call it from a user action, at a moment the user
    /// understands why: a browser refuses otherwise, with `notAllowed`.
    public func requestAuthorization(
        _ options: AuthorizationOptions = [.alert, .sound, .badge],
        completion: @escaping (Result<PermissionStatus, NotificationError>) -> Void
    ) {
        notifications.requestAuthorization(options.rawValue, callback: Receiver.settings { result in
            completion(result.map { $0.authorizationStatus })
        })
    }

    /// Asks for scheduled notifications to arrive on time, where that's
    /// the user's to grant: Android sends them to its setting, and this
    /// answers when they come back. An alarm clock asks; a reminder
    /// needn't.
    public func requestExactTiming(completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        notifications.requestExactTiming(Receiver.settings(completion))
    }

    // MARK: Categories

    /// The app's kinds of notification, replacing those set before. Set
    /// them at every launch, before anything else.
    public func setCategories(_ categories: [NotificationCategory]) {
        let notifications = self.notifications
        notifications.beginCategories()
        for category in categories {
            notifications.addCategory(category.identifier, name: category.name, interruption: category.interruption.rawValue,
                                      sound: category.sound.kind, soundName: category.sound.name)
            for action in category.actions {
                if let input = action.textInput {
                    notifications.addTextAction(category.identifier, identifier: action.identifier, title: action.title,
                                                options: action.options.rawValue, buttonTitle: input.buttonTitle,
                                                placeholder: input.placeholder)
                } else {
                    notifications.addAction(category.identifier, identifier: action.identifier, title: action.title,
                                            options: action.options.rawValue)
                }
            }
        }
        notifications.endCategories()
    }

    // MARK: Requests

    /// Shows the notification, or schedules it. One with an identifier in
    /// use replaces the one before, pending or delivered.
    public func add(_ request: NotificationRequest, completion: @escaping (Result<Void, NotificationError>) -> Void) {
        notifications.add(request.record(), callback: Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// The identifiers scheduled and not yet delivered.
    public func pendingIdentifiers(completion: @escaping (Result<[String], NotificationError>) -> Void) {
        notifications.pending(Receiver.list(completion))
    }

    /// The identifiers delivered and still in the system's list.
    public func deliveredIdentifiers(completion: @escaping (Result<[String], NotificationError>) -> Void) {
        notifications.delivered(Receiver.list(completion))
    }

    /// Cancels scheduled notifications.
    public func removePending(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        notifications.removePending(identifiers)
    }

    public func removeAllPending() {
        notifications.removeAllPending()
    }

    /// Takes delivered notifications out of the system's list.
    public func removeDelivered(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        notifications.removeDelivered(identifiers)
    }

    public func removeAllDelivered() {
        notifications.removeAllDelivered()
    }

    /// The number on the app's icon; 0 clears it. Nothing where the
    /// platform has no number.
    public func setBadgeCount(_ count: Int) {
        notifications.setBadgeCount(Int32(truncatingIfNeeded: max(count, 0)))
    }

    // MARK: Delivery

    /// How a notification is shown when it arrives with the app in front.
    /// As usual, to begin with; empty for an app that shows it itself.
    public var foregroundPresentation: NotificationPresentationOptions = .all {
        didSet {
            notifications.setForegroundPresentation(foregroundPresentation.rawValue)
        }
    }

    /// Hears what the user did with a notification: a tap, or a button.
    /// The response that started the app waits until a handler is set.
    /// `nil` stops hearing, and responses wait again.
    public func onResponse(_ handler: ((NotificationResponse) -> Void)?) {
        events.responseGeneration &+= 1
        #if !EMBEDDED_NO_CONCURRENCY
        events.responseStream?.finish()
        events.responseStream = nil
        #endif
        setResponseHandler(handler)
    }

    /// Hears of each notification delivered while the app is running:
    /// local or pushed, shown or not.
    public func onReceive(_ handler: ((DeliveredNotification) -> Void)?) {
        events.receiveGeneration &+= 1
        #if !EMBEDDED_NO_CONCURRENCY
        events.receiveStream?.finish()
        events.receiveStream = nil
        #endif
        setReceiveHandler(handler)
    }

    private func setResponseHandler(_ handler: ((NotificationResponse) -> Void)?) {
        events.onResponse = handler
        listen()
        // What came while only deliveries were listened for.
        if let handler {
            let waiting = events.waiting
            events.waiting = []
            for response in waiting {
                handler(response)
            }
        }
    }

    private func setReceiveHandler(_ handler: ((DeliveredNotification) -> Void)?) {
        events.onReceive = handler
        listen()
    }

    /// Listens while anything wants to hear. The host keeps responses
    /// while nothing does.
    private func listen() {
        let wanted = events.onResponse != nil || events.onReceive != nil
        guard wanted != events.isListening else { return }
        events.isListening = wanted
        notifications.setDelegate(wanted ? events : nil)
    }

    // MARK: Push

    /// Asks the platform's push service for the app's address, to give to
    /// the app's server. Register at every launch: the address can change.
    /// Ask for authorization first: a browser gives no address without it.
    ///
    /// `applicationServerKey` is Web Push's, base64url; other services
    /// ignore it.
    public func registerForRemoteNotifications(
        applicationServerKey: String? = nil,
        completion: @escaping (Result<PushSubscription, NotificationError>) -> Void
    ) {
        push.register(applicationServerKey, callback: PushReceiver { outcome in
            if case .registered(let subscription) = outcome {
                completion(.success(subscription))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Stops pushes to this install.
    public func unregisterForRemoteNotifications(completion: @escaping (Result<Void, NotificationError>) -> Void) {
        push.unregister(PushReceiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Hears when the app's push address changes while it runs.
    public func onSubscriptionChange(_ handler: ((PushSubscription) -> Void)?) {
        pushEvents.generation &+= 1
        #if !EMBEDDED_NO_CONCURRENCY
        pushEvents.stream?.finish()
        pushEvents.stream = nil
        #endif
        setSubscriptionHandler(handler)
    }

    private func setSubscriptionHandler(_ handler: ((PushSubscription) -> Void)?) {
        pushEvents.handler = handler
        push.setDelegate(handler == nil ? nil : pushEvents)
    }

    // MARK: Async

    #if !EMBEDDED_NO_CONCURRENCY
    /// Where the user's permission stands. Never prompts.
    public nonisolated(nonsending) func settings() async throws(NotificationError) -> NotificationSettings {
        try await wait { self.settings(completion: $0) }
    }

    /// Asks the user, the first time; answers the same without asking
    /// after that.
    @discardableResult
    public nonisolated(nonsending) func requestAuthorization(
        _ options: AuthorizationOptions = [.alert, .sound, .badge]
    ) async throws(NotificationError) -> PermissionStatus {
        try await wait { self.requestAuthorization(options, completion: $0) }
    }

    /// Asks for scheduled notifications to arrive on time.
    @discardableResult
    public nonisolated(nonsending) func requestExactTiming() async throws(NotificationError) -> NotificationSettings {
        try await wait { self.requestExactTiming(completion: $0) }
    }

    /// Shows the notification, or schedules it.
    public nonisolated(nonsending) func add(_ request: NotificationRequest) async throws(NotificationError) {
        try await wait { self.add(request, completion: $0) }
    }

    public nonisolated(nonsending) func pendingIdentifiers() async throws(NotificationError) -> [String] {
        try await wait { self.pendingIdentifiers(completion: $0) }
    }

    public nonisolated(nonsending) func deliveredIdentifiers() async throws(NotificationError) -> [String] {
        try await wait { self.deliveredIdentifiers(completion: $0) }
    }

    /// Asks the platform's push service for the app's address.
    public nonisolated(nonsending) func registerForRemoteNotifications(
        applicationServerKey: String? = nil
    ) async throws(NotificationError) -> PushSubscription {
        try await wait { self.registerForRemoteNotifications(applicationServerKey: applicationServerKey, completion: $0) }
    }

    public nonisolated(nonsending) func unregisterForRemoteNotifications() async throws(NotificationError) {
        try await wait { self.unregisterForRemoteNotifications(completion: $0) }
    }

    /// What the user did with notifications, as it happens. The response
    /// that started the app waits until this is first read.
    ///
    /// One listener at a time: reading it again finishes the stream
    /// before, and so does `onResponse`.
    public var responses: EventStream<NotificationResponse, Never> {
        let (stream, continuation) = EventStream<NotificationResponse, Never>.makeStream()
        events.responseGeneration &+= 1
        let generation = events.responseGeneration
        events.responseStream?.finish()
        events.responseStream = continuation
        continuation.onTermination = { [self] in
            guard events.responseGeneration == generation else { return }
            events.responseStream = nil
            setResponseHandler(nil)
        }
        setResponseHandler { continuation.yield($0) }
        return stream
    }

    /// Each notification delivered while the app is running.
    public var received: EventStream<DeliveredNotification, Never> {
        let (stream, continuation) = EventStream<DeliveredNotification, Never>.makeStream()
        events.receiveGeneration &+= 1
        let generation = events.receiveGeneration
        events.receiveStream?.finish()
        events.receiveStream = continuation
        continuation.onTermination = { [self] in
            guard events.receiveGeneration == generation else { return }
            events.receiveStream = nil
            setReceiveHandler(nil)
        }
        setReceiveHandler { continuation.yield($0) }
        return stream
    }

    /// The app's push address, each time it changes while the app runs.
    public var subscriptionChanges: EventStream<PushSubscription, Never> {
        let (stream, continuation) = EventStream<PushSubscription, Never>.makeStream()
        pushEvents.generation &+= 1
        let generation = pushEvents.generation
        pushEvents.stream?.finish()
        pushEvents.stream = continuation
        continuation.onTermination = { [self] in
            guard pushEvents.generation == generation else { return }
            pushEvents.stream = nil
            setSubscriptionHandler(nil)
        }
        setSubscriptionHandler { continuation.yield($0) }
        return stream
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(
        _ start: (@escaping (Result<Value, NotificationError>) -> Void) -> Void
    ) async throws(NotificationError) -> Value {
        try await withCallback { (callback: Callback<Value, NotificationError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// The delegate behind `responses`, `received` and their closure forms.
final class NotificationEvents: NotificationsDelegate {

    var onResponse: ((NotificationResponse) -> Void)?

    var onReceive: ((DeliveredNotification) -> Void)?

    /// Responses that came while only deliveries were listened for.
    var waiting: [NotificationResponse] = []

    var isListening = false

    var responseGeneration = 0

    var receiveGeneration = 0

    #if !EMBEDDED_NO_CONCURRENCY
    var responseStream: EventStream<NotificationResponse, Never>.Continuation?

    var receiveStream: EventStream<DeliveredNotification, Never>.Continuation?
    #endif

    func didReceive(_ notification: any NotificationRecord) {
        onReceive?(DeliveredNotification(notification))
    }

    func didRespond(_ notification: any NotificationRecord, action: String, text: String?) {
        let response = NotificationResponse(notification: DeliveredNotification(notification), actionIdentifier: action, text: text)
        if let onResponse {
            onResponse(response)
        } else {
            waiting.append(response)
        }
    }
}

/// The delegate behind `subscriptionChanges` and `onSubscriptionChange`.
final class PushEvents: PushDelegate {

    var handler: ((PushSubscription) -> Void)?

    var generation = 0

    #if !EMBEDDED_NO_CONCURRENCY
    var stream: EventStream<PushSubscription, Never>.Continuation?
    #endif

    func didChangeRegistration(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool) {
        handler?(PushSubscription(service: PushService(rawValue: service), address: address, publicKey: publicKey,
                                  authSecret: authSecret, isDevelopment: development))
    }
}

/// What a `NotificationCallback` was told.
enum NotificationOutcome {

    case complete
    case settings(NotificationSettings)
    case list([String])
    case failure(NotificationError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: NotificationError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
final class Receiver: NotificationCallback {

    private var finish: ((NotificationOutcome) -> Void)?

    init(_ finish: @escaping (NotificationOutcome) -> Void) {
        self.finish = finish
    }

    static func settings(_ completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .settings(let settings) = outcome {
                completion(.success(settings))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    static func list(_ completion: @escaping (Result<[String], NotificationError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .list(let identifiers) = outcome {
                completion(.success(identifiers))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: NotificationOutcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didGetSettings(_ status: Int32, enabled: Int32) {
        answer(.settings(NotificationSettings(status: status, enabled: enabled)))
    }

    func didList(_ identifiers: [String]) {
        answer(.list(identifiers))
    }

    func didFail(_ error: Int32) {
        answer(.failure(NotificationError(rawValue: error) ?? .unknown))
    }
}

/// What a `PushCallback` was told.
enum PushOutcome {

    case registered(PushSubscription)
    case complete
    case failure(NotificationError)

    var error: NotificationError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One push operation's callback.
final class PushReceiver: PushCallback {

    private var finish: ((PushOutcome) -> Void)?

    init(_ finish: @escaping (PushOutcome) -> Void) {
        self.finish = finish
    }

    private func answer(_ outcome: PushOutcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didRegister(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool) {
        answer(.registered(PushSubscription(service: PushService(rawValue: service), address: address, publicKey: publicKey,
                                           authSecret: authSecret, isDevelopment: development)))
    }

    func didComplete() {
        answer(.complete)
    }

    func didFail(_ error: Int32) {
        answer(.failure(NotificationError(rawValue: error) ?? .unknown))
    }
}
