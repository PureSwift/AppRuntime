import Foundation
import Testing
import CRuntime
import DynamicNotifications
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimeNotifications

/// A host's notification centre kept in memory: it holds what's scheduled,
/// and the test says when each fires and what the user does.
final class LinkedTestCentre: NotificationPresenter {

    var status: PermissionStatus = .notDetermined

    var prompts = 0

    var categories: [NotificationCategory] = []

    var pendingNotifications: [HostNotification] = []

    var deliveredNotifications: [HostNotification] = []

    var subscription: PushSubscription?

    var serverKey: String?

    func settings(_ completion: @escaping (NotificationSettings) -> Void) {
        completion(NotificationSettings(authorizationStatus: status, alerts: status == .granted, sounds: status == .granted,
                                        exactTiming: true, deliversWhenClosed: true))
    }

    func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        if status == .notDetermined {
            // The user says yes.
            prompts += 1
            status = .granted
        }
        settings { completion(.success($0)) }
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

    func setBadgeCount(_ count: Int) { }

    func setForegroundPresentation(_ options: NotificationPresentationOptions) { }

    func registerForPush(serverKey: String?, completion: @escaping (Result<PushSubscription, NotificationError>) -> Void) {
        self.serverKey = serverKey
        completion(subscription.map(Result.success) ?? .failure(.unavailable))
    }

    func unregisterForPush(_ completion: @escaping (NotificationError?) -> Void) {
        completion(nil)
    }

    /// The timer's time has come: the system shows its notification, and
    /// the app hears, since it's running.
    func fire(_ identifier: String) -> HostNotification? {
        guard let index = pendingNotifications.firstIndex(where: { $0.identifier == identifier }) else { return nil }
        let notification = pendingNotifications.remove(at: index)
        deliveredNotifications.append(notification)
        HostNotifications.received(notification)
        return notification
    }
}

/// `ExampleNotifications`'s library with the shared host implementation
/// over a notification centre the test keeps: the guest's
/// `UserNotificationCenter`, the `Notifications` and `PushNotifications`
/// contracts, and `HostNotifications`, in an Embedded guest, as a native
/// slice or through wasm2c (see `Package.swift`). The same checks as
/// `RuntimeWasm`'s WasmKit test. Part of `LinkedSliceTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleNotifications: Bool {
        #if LINKED_EXAMPLENOTIFICATIONS
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleNotifications, "Link ExampleNotifications's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleNotifications() throws {
        #if LINKED_EXAMPLENOTIFICATIONS
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let centre = LinkedTestCentre()
        HostNotifications.reset()
        HostNotifications.presenter = centre
        // The host answers at once, so each tap's effect is there when the
        // tap returns.
        HostNotifications.deliver = { $0() }
        HostNotificationsModule.register(in: native)
        defer { HostNotifications.reset() }
        TestRenderer.last = nil

        // The user tapped a timer's notification, and that started the app.
        HostNotifications.responded(to: HostNotification(identifier: "timer-9", title: "Timer 9", category: "timer", userInfo: ["minutes": "5"]))

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }

        // What started the app was waiting for it, and its categories are set.
        #expect(text("response") == "Opened timer-9")
        #expect(centre.categories.map(\.identifier) == ["timer"])
        #expect(centre.categories.first?.actions.map(\.identifier) == ["repeat", "stop"])
        #expect(centre.categories.first?.interruption == .timeSensitive)
        #expect(text("permission") == "Not asked")
        #expect(centre.prompts == 0, "nothing is asked until the user presses the button")

        // Without the user's leave nothing is scheduled, and the app is told.
        try tap("Start 5 min")
        #expect(text("status") == "Couldn\u{27}t start: error 2")
        #expect(centre.pendingNotifications.isEmpty)

        try tap("Allow")
        #expect(text("permission") == "Allowed" && centre.prompts == 1)

        // A timer is a notification the system holds until its time.
        try tap("Start 5 min")
        #expect(text("status") == "Started timer-2")
        #expect(centre.pendingNotifications == [HostNotification(
            identifier: "timer-2", title: "Timer 2", body: "5 minutes are up.", category: "timer",
            userInfo: ["minutes": "5"], trigger: .interval(seconds: 300, repeats: false)
        )])
        try tap("Start 5 min")
        #expect(centre.pendingNotifications.map(\.identifier) == ["timer-2", "timer-3"])
        #expect(renderer.screen?.button("Cancel timer-2") != nil && renderer.screen?.button("Cancel timer-3") != nil)
        try tap("Cancel timer-2")
        #expect(centre.pendingNotifications.map(\.identifier) == ["timer-3"])
        #expect(renderer.screen?.button("Cancel timer-2") == nil)

        // It fires while the app is open: the app hears, and its list follows.
        let fired = try #require(centre.fire("timer-3"))
        #expect(text("received") == "Rang: Timer 3")
        #expect(renderer.screen?.button("Cancel timer-3") == nil)

        // The user presses its buttons.
        HostNotifications.responded(to: fired, action: "repeat")
        #expect(text("response") == "Repeated timer-3")
        #expect(centre.pendingNotifications.map(\.identifier) == ["timer-3"], "scheduled again, from what the notification carried")
        #expect(centre.pendingNotifications.first?.trigger == .interval(seconds: 300, repeats: false))
        #expect(renderer.screen?.button("Cancel timer-3") != nil)
        HostNotifications.responded(to: fired, action: "stop")
        #expect(text("response") == "Stopped timer-3")
        #expect(centre.pendingNotifications.isEmpty && centre.deliveredNotifications.isEmpty)

        // One with no trigger is shown now.
        try tap("Notify Now")
        #expect(text("status") == "Shown")
        #expect(centre.deliveredNotifications.map(\.identifier) == ["now"])

        // Push has to be in the manifest; then the app gets its address.
        centre.subscription = PushSubscription(service: .apns, address: "a1b2c3", isDevelopment: true)
        try tap("Register")
        #expect(text("address") == "Push: error 7")
        HostNotifications.declaresRemote = true
        try tap("Register")
        #expect(text("address") == "apns a1b2c3")
        #expect(centre.serverKey == "example-server-key")
        #endif
    }
}
