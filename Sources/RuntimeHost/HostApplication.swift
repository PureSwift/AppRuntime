import DynamicRuntime

/// The built-in `Application` contract, for hosts whose platform reports
/// lifecycle and URLs to the host rather than to an object the guest makes:
/// the host calls `setState`, `open` and `didReceiveMemoryWarning`, and each
/// `Application` the guest made hears about it. The platform host opens
/// URLs and keeps the screen awake through `openURL` and
/// `idleTimerDisabledChanged`.
///
/// Main thread only.
public final class HostApplication: Application {

    /// The app's state now.
    nonisolated(unsafe) public private(set) static var current: ApplicationState = .active

    nonisolated(unsafe) private static var instances: [Weak] = []

    /// Opens a URL in the app that handles it; whether it could. Without
    /// it, nothing is opened and the answer is `false`.
    nonisolated(unsafe) public static var openURL: ((String) -> Bool)?

    /// Called when whether the screen should stay awake changes: an
    /// `Application` asks, and the app isn't in the background.
    nonisolated(unsafe) public static var idleTimerDisabledChanged: ((Bool) -> Void)?

    /// What `idleTimerDisabledChanged` was last told.
    nonisolated(unsafe) public private(set) static var isIdleTimerDisabled = false

    let delegate: any ApplicationDelegate

    /// This application's switch.
    private var disablesIdleTimer = false

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    deinit {
        if disablesIdleTimer {
            // The weak reference is already nil.
            Self.updateIdleTimer()
        }
    }

    public static func make(_ delegate: any ApplicationDelegate) -> HostApplication {
        let application = HostApplication(delegate: delegate)
        instances.removeAll { $0.object == nil }
        instances.append(Weak(object: application))
        return application
    }

    public func state() -> Int32 {
        Self.current.rawValue
    }

    /// A URL that names a file is refused: a guest can't name one outside
    /// its container, and one inside it is for `Documents`' export.
    public func openURL(_ url: String) -> Bool {
        guard !Self.namesFile(url), let open = Self.openURL else { return false }
        return open(url)
    }

    public func setIdleTimerDisabled(_ disabled: Bool) {
        guard disabled != disablesIdleTimer else { return }
        disablesIdleTimer = disabled
        Self.updateIdleTimer()
    }

    static func namesFile(_ url: String) -> Bool {
        let scheme = url.prefix { $0 != ":" }
        return scheme.count < url.count && scheme.lowercased() == "file"
    }

    private static func updateIdleTimer() {
        let disabled = current != .background && live.contains { $0.disablesIdleTimer }
        guard disabled != isIdleTimerDisabled else { return }
        isIdleTimerDisabled = disabled
        idleTimerDisabledChanged?(disabled)
    }

    // MARK: Host side

    /// Reports a new state to every `Application` the guest made.
    public static func setState(_ state: ApplicationState) {
        guard state != current else { return }
        current = state
        updateIdleTimer()
        for application in live {
            application.delegate.didChangeState(application, state: state.rawValue)
        }
    }

    /// Asks the guest to open `url`; whether any `Application` handled it.
    @discardableResult
    public static func open(_ url: String) -> Bool {
        var handled = false
        for application in live where application.delegate.open(application, url: url) {
            handled = true
        }
        return handled
    }

    public static func didReceiveMemoryWarning() {
        for application in live {
            application.delegate.didReceiveMemoryWarning(application)
        }
    }

    /// Forgets every `Application` and goes back to `active`, for tests and
    /// for a host that starts the guest again.
    public static func reset() {
        instances = []
        current = .active
        openURL = nil
        idleTimerDisabledChanged = nil
        isIdleTimerDisabled = false
    }

    private static var live: [HostApplication] {
        instances.compactMap(\.object)
    }

    private struct Weak {
        weak var object: HostApplication?
    }
}
