import DynamicRuntime

/// The built-in `Application` contract, for hosts whose platform reports
/// lifecycle and URLs to the host rather than to an object the guest makes:
/// the host calls `setState`, `open` and `didReceiveMemoryWarning`, and each
/// `Application` the guest made hears about it.
///
/// Main thread only.
public final class HostApplication: Application {

    /// The app's state now.
    nonisolated(unsafe) public private(set) static var current: ApplicationState = .active

    nonisolated(unsafe) private static var instances: [Weak] = []

    let delegate: any ApplicationDelegate

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
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

    // MARK: Host side

    /// Reports a new state to every `Application` the guest made.
    public static func setState(_ state: ApplicationState) {
        guard state != current else { return }
        current = state
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
    }

    private static var live: [HostApplication] {
        instances.compactMap(\.object)
    }

    private struct Weak {
        weak var object: HostApplication?
    }
}
