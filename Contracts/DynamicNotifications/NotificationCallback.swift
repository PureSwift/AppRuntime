import DynamicRuntime

/// The outcome of one `Notifications` operation. The host calls exactly one
/// of these, once, on the main thread.
@DynamicCallback("org.pureswift.notifications.Callback")
public protocol NotificationCallback: AnyObject {

    func didComplete()

    /// `status` is a `PermissionStatus` raw value. `enabled` are bits of
    /// `NotificationSettings`: 1 alerts, 2 sounds, 4 badges, 8 exact
    /// timing, 16 delivers when the app is closed.
    func didGetSettings(_ status: Int32, enabled: Int32)

    func didList(_ identifiers: [String])

    /// `error` is a `NotificationError` raw value.
    func didFail(_ error: Int32)
}

/// What arrives, and what the user did. Called on the main thread.
@DynamicCallback("org.pureswift.notifications.Delegate")
public protocol NotificationsDelegate: AnyObject {

    /// A notification was delivered while the app is running: local or
    /// pushed, shown or not.
    func didReceive(_ notification: NotificationRecord)

    /// The user tapped the notification (`action` is empty) or chose one
    /// of its buttons. `text` is what they typed, for a text action.
    func didRespond(_ notification: NotificationRecord, action: String, text: String?)
}
