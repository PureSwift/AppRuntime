/// The built-in `Application` contract: the app's lifecycle, incoming
/// URLs, opening URLs in other apps, and keeping the screen awake
/// (`Documentation/Contracts/Application.md`).
///
/// A file the app is opened with isn't a URL here: a guest can't open a
/// path outside its container. It arrives as a document, through
/// `DynamicDocuments`.
///
/// Every host provides it. The app makes one, normally in `rt_main`, and the
/// host reports to its delegate on the main thread until the app releases
/// it.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `UIApplication` / scene notifications; `scene(_:openURLContexts:)` |
/// | macOS | `NSApplication` notifications; `application(_:open:)` |
/// | Android | `ProcessLifecycleOwner`, `onTrimMemory`; `ACTION_VIEW` intents for links |
/// | Linux | window focus and visibility; `.desktop` URL handlers |
@DynamicRuntime("org.pureswift.runtime.Application")
public protocol Application: AnyObject {

    /// Never blocks. The host keeps `delegate` while the application lives.
    static func make(_ delegate: ApplicationDelegate) throws(RuntimeError) -> Self

    /// An `ApplicationState` raw value.
    func state() throws(RuntimeError) -> Int32

    /// Asks the platform to open `url` in the app that handles it. Whether
    /// it could: there's an app for it, and the URL is well formed. On iOS,
    /// whether the system was asked; its answer comes later, and isn't
    /// passed on.
    func openURL(_ url: String) throws(RuntimeError) -> Bool

    /// While true, the screen doesn't dim or lock for want of input, while
    /// the app is in the foreground. The last call wins.
    func setIdleTimerDisabled(_ disabled: Bool) throws(RuntimeError)
}

/// What a host that hasn't implemented these does: opens nothing, and
/// lets the screen sleep.
public extension Application {

    func openURL(_ url: String) throws(RuntimeError) -> Bool {
        false
    }

    func setIdleTimerDisabled(_ disabled: Bool) throws(RuntimeError) { }
}

/// Lifecycle events and URLs, from the host.
@DynamicCallback("org.pureswift.runtime.ApplicationDelegate")
public protocol ApplicationDelegate: AnyObject {

    /// `state` is an `ApplicationState` raw value.
    func didChangeState(_ application: Application, state: Int32)

    /// Free what can be rebuilt; the host may end the app otherwise.
    func didReceiveMemoryWarning(_ application: Application)

    /// A URL the app was opened with: a deep link or a custom scheme.
    /// Returns whether the app handled it.
    func open(_ application: Application, url: String) -> Bool
}

/// `Application.state()`. The raw values match `UIApplication.State`.
public enum ApplicationState: Int32, Sendable {

    /// In the foreground and receiving events.
    case active = 0

    /// In the foreground but not receiving events: a call, the app switcher,
    /// a window that isn't key.
    case inactive = 1

    /// Not visible. The host may suspend the app soon.
    case background = 2
}
