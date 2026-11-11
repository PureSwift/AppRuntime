/// The built-in `Application` contract: the app's lifecycle and incoming
/// URLs.
///
/// Every host provides it. The app makes one, normally in `rt_main`, and the
/// host reports to its delegate on the main thread until the app releases
/// it.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `UIApplication` / scene notifications; `scene(_:openURLContexts:)` |
/// | macOS | `NSApplication` notifications; `application(_:open:)` |
/// | Android | `ProcessLifecycleOwner`, `onTrimMemory`; `ACTION_VIEW` intents |
/// | Linux | window focus and visibility; `.desktop` URL handlers |
@DynamicRuntime("org.pureswift.runtime.Application")
public protocol Application: AnyObject {

    /// Never blocks. The host keeps `delegate` while the application lives.
    static func make(_ delegate: ApplicationDelegate) throws(RuntimeError) -> Self

    /// An `ApplicationState` raw value.
    func state() throws(RuntimeError) -> Int32
}

/// Lifecycle events and URLs, from the host.
@DynamicCallback("org.pureswift.runtime.ApplicationDelegate")
public protocol ApplicationDelegate: AnyObject {

    /// `state` is an `ApplicationState` raw value.
    func didChangeState(_ application: Application, state: Int32)

    /// Free what can be rebuilt; the host may end the app otherwise.
    func didReceiveMemoryWarning(_ application: Application)

    /// A URL the app was opened with: a deep link, a custom scheme, a file.
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
