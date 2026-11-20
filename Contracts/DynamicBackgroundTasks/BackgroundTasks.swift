import DynamicRuntime

/// Running the app's code while it isn't in front: tasks the system starts
/// from time to time, and time the app asks for to finish something
/// (`Documentation/Contracts/BackgroundTasks.md`). App code uses
/// `BackgroundTaskScheduler`, which wraps this contract.
///
/// In the background the app runs only while a run or an activity is open:
/// a run the host began by calling the delegate, or an activity the app
/// began. With neither, the host may stop the app at once.
///
/// The system decides when a task runs. A request says no sooner than, and
/// about how often; later is always allowed, and so is never.
///
/// `.backgroundTasks` prompts for nothing: the system's own switch is the
/// user's control, and `status` reads it.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `BGTaskScheduler`; `beginBackgroundTask` for an activity |
/// | Android | `WorkManager` |
/// | Linux | the OS's background service |
/// | macOS | `NSBackgroundActivityScheduler`, while the app is open |
/// | Browser | none |
@DynamicRuntime("org.pureswift.background.Tasks", requires: .backgroundTasks)
public protocol BackgroundTasks: AnyObject {

    static func shared() -> Self

    /// Whether the app may run in the background: a `PermissionStatus` raw
    /// value. Never prompts.
    func status() -> Int32

    /// Where runs are announced. The app sets it before `rt_main` returns:
    /// a run with nobody to announce it to fails.
    func setDelegate(_ delegate: BackgroundTasksDelegate?)

    /// Asks for a task to be run, replacing a request with the same
    /// identifier. `kind` is a `BackgroundTaskKind` raw value. `earliest`
    /// is seconds from now before which it won't run. `interval` is seconds
    /// between runs, 900 or more, or 0 for once. `requirements` are bits of
    /// `BackgroundTaskRequirements`. Answers `didComplete`.
    func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32, callback: BackgroundCallback)

    func cancel(_ identifier: String)

    func cancelAll()

    /// The identifiers asked for and not cancelled. Answers `didList`.
    func pending(_ callback: BackgroundCallback)

    /// A run the delegate was told of is over.
    func complete(_ run: Int32, success: Bool)

    /// Begins an activity, to keep the app running a little longer. 0: the
    /// host can't.
    func beginActivity(_ name: String) -> Int32

    func endActivity(_ activity: Int32)

    /// Seconds before the host stops the app; -1 where it isn't known or
    /// isn't limited.
    func timeRemaining() -> Double
}

/// Tasks to run, and time running out. Called on the main thread.
@DynamicCallback("org.pureswift.background.TasksDelegate")
public protocol BackgroundTasksDelegate: AnyObject {

    /// Do the task's work, then call `complete` with `run`.
    func run(_ identifier: String, run: Int32)

    /// Out of time: stop, and complete the run now.
    func didExpire(_ run: Int32)

    /// Out of time for an activity the app began. It has ended.
    func didExpireActivity(_ activity: Int32)
}

/// The outcome of one `BackgroundTasks` operation. The host calls exactly
/// one of these, once, on the main thread.
@DynamicCallback("org.pureswift.background.Callback")
public protocol BackgroundCallback: AnyObject {

    func didComplete()

    func didList(_ identifiers: [String])

    /// `error` is a `BackgroundError` raw value.
    func didFail(_ error: Int32)
}
