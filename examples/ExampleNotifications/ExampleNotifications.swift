import DynamicRuntime
import DynamicNotifications
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example notifications app: kitchen timers. It asks the user's leave,
/// schedules a notification for when each timer ends, lists and cancels
/// them, answers the notification's buttons, and registers for pushes.

struct Entry: Identifiable {
    /// A pending notification's identifier.
    let id: String
}

/// The closures hold the timers, which live as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Timers: @unchecked Sendable {

    var permission: String = "Not asked"

    /// The timers still running.
    var pending: [Entry] = []

    /// What the user last did with a notification.
    var response: String = ""

    /// The last timer that ended while the app was open.
    var received: String = ""

    /// Where the app's server would send a push.
    var address: String = ""

    var status: String = ""

    @ObservationIgnored var next: Int = 1

    @ObservationIgnored let center = UserNotificationCenter.current

    func start() {
        // A kind of notification, with its buttons. Set at every launch.
        center.setCategories([
            NotificationCategory(
                identifier: "timer", name: "Timers",
                actions: [
                    NotificationAction(identifier: "repeat", title: "Repeat"),
                    NotificationAction(identifier: "stop", title: "Stop", options: .destructive),
                ],
                interruption: .timeSensitive),
        ])
        // The response that started the app arrives here too.
        center.onResponse { response in
            self.answer(response)
        }
        center.onReceive { notification in
            self.received = "Rang: \(notification.content.title)"
            self.refresh()
        }
        center.settings { result in
            if case .success(let settings) = result {
                self.show(settings.authorizationStatus)
            }
        }
        refresh()
    }

    func show(_ status: PermissionStatus) {
        switch status {
        case .granted, .limited: permission = "Allowed"
        case .notDetermined: permission = "Not asked"
        case .unavailable: permission = "No notifications here"
        default: permission = "Refused"
        }
    }

    /// From a button: the user knows why they're asked.
    func allow() {
        center.requestAuthorization([.alert, .sound]) { result in
            switch result {
            case .success(let status):
                self.show(status)
            case .failure(let error):
                self.status = "Couldn't ask: error \(error.rawValue)"
            }
        }
    }

    func startTimer(minutes: Int) {
        let identifier = "timer-\(next)"
        var content = NotificationContent()
        content.title = "Timer \(next)"
        content.body = "\(minutes) minutes are up."
        content.categoryIdentifier = "timer"
        content.userInfo = ["minutes": "\(minutes)"]
        schedule(identifier, content, minutes: minutes, then: "Started \(identifier)")
        next += 1
    }

    func schedule(_ identifier: String, _ content: NotificationContent, minutes: Int, then done: String) {
        let request = NotificationRequest(identifier: identifier, content: content, trigger: .timeInterval(Double(minutes * 60)))
        center.add(request) { result in
            switch result {
            case .success:
                self.status = done
                self.refresh()
            case .failure(let error):
                self.status = "Couldn't start: error \(error.rawValue)"
            }
        }
    }

    func cancel(_ identifier: String) {
        center.removePending([identifier])
        status = "Cancelled \(identifier)"
        refresh()
    }

    /// With no trigger, it's shown now.
    func notifyNow() {
        center.add(NotificationRequest(identifier: "now", content: NotificationContent(title: "Timers", body: "Hello."))) { result in
            switch result {
            case .success:
                self.status = "Shown"
            case .failure(let error):
                self.status = "Couldn't show: error \(error.rawValue)"
            }
        }
    }

    func refresh() {
        center.pendingIdentifiers { result in
            if case .success(let identifiers) = result {
                self.pending = identifiers.map { Entry(id: $0) }
            }
        }
    }

    /// A tap on the notification, or one of its buttons.
    func answer(_ response: NotificationResponse) {
        let notification = response.notification
        switch response.actionIdentifier {
        case NotificationAction.defaultIdentifier:
            self.response = "Opened \(notification.identifier)"
        case "repeat":
            let minutes = Int(notification.userInfo["minutes"] ?? "") ?? 5
            self.response = "Repeated \(notification.identifier)"
            schedule(notification.identifier, notification.content, minutes: minutes, then: "Started \(notification.identifier)")
        case "stop":
            self.response = "Stopped \(notification.identifier)"
            center.removePending([notification.identifier])
            center.removeDelivered([notification.identifier])
            refresh()
        default:
            self.response = "Unknown action"
        }
    }

    /// The address a server would push to. Asked for after permission: a
    /// browser gives none without it.
    func register() {
        center.registerForRemoteNotifications(applicationServerKey: "example-server-key") { result in
            switch result {
            case .success(let subscription):
                let service: String
                switch subscription.service {
                case .apns: service = "apns"
                case .fcm: service = "fcm"
                case .webPush: service = "webPush"
                default: service = "other"
                }
                self.address = "\(service) \(subscription.address)"
            case .failure(let error):
                self.address = "Push: error \(error.rawValue)"
            }
        }
    }
}

struct ContentView: View {

    let timers: Timers

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(timers.permission)
                .accessibilityIdentifier("permission")
            HStack(spacing: 8) {
                Button("Allow") { timers.allow() }
                Button("Start 5 min") { timers.startTimer(minutes: 5) }
                Button("Notify Now") { timers.notifyNow() }
                Button("Register") { timers.register() }
            }
            ForEach(timers.pending) { entry in
                Button("Cancel \(entry.id)") { timers.cancel(entry.id) }
            }
            Text(timers.response)
                .accessibilityIdentifier("response")
            Text(timers.received)
                .accessibilityIdentifier("received")
            Text(timers.address)
                .accessibilityIdentifier("address")
            Text(timers.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleNotificationsApp: App {

    let timers = Timers()

    init() {
        timers.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(timers: timers)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleNotificationsMain() -> rt_status {
    Runtime.main { ExampleNotificationsApp.run() }
}
