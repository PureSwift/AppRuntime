/// Guest-side names for what the `BackgroundTasks` contract carries.

/// How much time a task needs, and when it's best run.
public enum BackgroundTaskKind: Int32, Sendable {

    /// Short and frequent: fetching what's new. About half a minute on iOS.
    case refresh = 0

    /// Long and rare, when the device is idle: indexing, cleaning up.
    case processing = 1
}

/// What a task waits for.
public struct BackgroundTaskRequirements: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let network = BackgroundTaskRequirements(rawValue: 1 << 0)
    public static let charging = BackgroundTaskRequirements(rawValue: 1 << 1)
}

/// A task for the system to run: which, how often, and what it needs.
///
/// ```swift
/// BackgroundTaskRequest("org.example.mail.sync", every: 30 * 60, requiresNetwork: true)
/// ```
///
/// The system decides when. It won't run sooner than `earliest`, or more
/// often than `every`; it may run much later, or never.
public struct BackgroundTaskRequest: Equatable, Sendable {

    /// The shortest `every`, in seconds: a quarter of an hour.
    public static let shortestInterval: Double = 900

    /// A task the manifest names.
    public var identifier: String

    public var kind: BackgroundTaskKind

    /// Seconds from now before which it won't run. 0: any time.
    public var earliest: Double

    /// Seconds between runs, 900 or more. `nil`: once.
    public var every: Double?

    /// Wait for a network. A refresh on iOS can't ask: it's run when the
    /// system thinks best.
    public var requiresNetwork: Bool

    /// Wait until the device is charging.
    public var requiresCharging: Bool

    public init(
        _ identifier: String,
        kind: BackgroundTaskKind = .refresh,
        earliest: Double = 0,
        every: Double? = nil,
        requiresNetwork: Bool = false,
        requiresCharging: Bool = false
    ) {
        self.identifier = identifier
        self.kind = kind
        self.earliest = earliest
        self.every = every
        self.requiresNetwork = requiresNetwork
        self.requiresCharging = requiresCharging
    }

    public var requirements: BackgroundTaskRequirements {
        var requirements: BackgroundTaskRequirements = []
        if requiresNetwork {
            requirements.insert(.network)
        }
        if requiresCharging {
            requirements.insert(.charging)
        }
        return requirements
    }
}

/// Why a background operation failed.
public enum BackgroundError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. Hosts never send it.
    case cancelled = 1

    /// The manifest doesn't name the task.
    case notDeclared = 2

    /// Guest-side: no handler was registered for the task. Hosts never
    /// send it.
    case notRegistered = 3

    /// This host runs nothing in the background.
    case unsupported = 4

    /// An interval under 900 seconds, or a time before now.
    case invalid = 5

    /// The host keeps no more requests.
    case limitReached = 6
}
