import DynamicRuntime

/// Pushes from the app's server: where to send them. A second contract
/// beside `Notifications`, so an app's contract list says whether it uses
/// push; the manifest then has to declare it
/// (`.notifications(remote: true)`).
///
/// A push that shows something is shown by the system, as a local
/// notification is, and reaches the app through `NotificationsDelegate`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | APNs: `registerForRemoteNotifications` |
/// | Android | Firebase Cloud Messaging |
/// | Linux | the OS's push service |
/// | Browser | the Push API: `PushManager.subscribe` |
@DynamicRuntime("org.pureswift.notifications.Push", requires: .notifications)
public protocol PushNotifications: AnyObject {

    static func shared() -> Self

    /// Asks the platform's push service for the app's address.
    /// `serverKey` is Web Push's application server key, base64url; other
    /// services ignore it. Answers `didRegister`.
    func register(_ serverKey: String?, callback: PushCallback)

    /// Stops pushes to this install. Answers `didComplete`.
    func unregister(_ callback: PushCallback)

    /// Hears when the address changes while the app runs.
    func setDelegate(_ delegate: PushDelegate?)
}

/// The outcome of one `PushNotifications` operation.
@DynamicCallback("org.pureswift.notifications.PushCallback")
public protocol PushCallback: AnyObject {

    /// `service` is a `PushService` raw value. `address` is the APNs
    /// device token in hex, the FCM registration token, or the Web Push
    /// endpoint URL. `publicKey` and `authSecret` are Web Push's `p256dh`
    /// and `auth`, base64url. `development` is APNs's sandbox.
    func didRegister(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool)

    func didComplete()

    /// `error` is a `NotificationError` raw value.
    func didFail(_ error: Int32)
}

/// A change of the app's push address. Called on the main thread.
@DynamicCallback("org.pureswift.notifications.PushDelegate")
public protocol PushDelegate: AnyObject {

    func didChangeRegistration(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool)
}
