import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// One run of a task the system started. Complete it when the work is
/// done, and stop when it expires.
///
/// It's guest-side only. The guest is single-threaded (§6.4).
public final class BackgroundTask: @unchecked Sendable {

    public let identifier: String

    let run: Int32

    private let tasks: any BackgroundTasks

    /// Called when time is up: stop the work, and complete the run now.
    public var onExpiration: (() -> Void)?

    public private(set) var isExpired = false

    public private(set) var isCompleted = false

    /// Lets go of the scheduler's note of this run.
    var finished: (() -> Void)?

    init(identifier: String, run: Int32, tasks: any BackgroundTasks) {
        self.identifier = identifier
        self.run = run
        self.tasks = tasks
    }

    /// The run is over. Only the first call counts. The host may stop the
    /// app once nothing else holds it.
    public func complete(success: Bool) {
        guard !isCompleted else { return }
        isCompleted = true
        onExpiration = nil
        tasks.complete(run, success: success)
        finished?()
        finished = nil
    }

    func expire() {
        guard !isCompleted, !isExpired else { return }
        isExpired = true
        onExpiration?()
    }
}

/// What the scheduler and an activity share: whether time ran out, and
/// whom to tell. The activity owns it; the scheduler only knows of it
/// while the activity is open.
final class ActivityState {

    var onExpiration: (() -> Void)?

    var isExpired: Bool

    var isEnded = false

    init(isExpired: Bool) {
        self.isExpired = isExpired
    }
}

/// Time the app asked for, to finish something after it leaves the front.
/// End it as soon as the work is done; one that's released ends too.
///
/// ```swift
/// let activity = scheduler.beginActivity("Saving draft")
/// drafts.save(draft) { activity.end() }
/// ```
///
/// Where the host can't keep the app running, it has expired already, and
/// the work goes on only while the system lets it.
public final class BackgroundActivity: @unchecked Sendable {

    public let name: String

    let number: Int32

    let state: ActivityState

    private let scheduler: BackgroundTaskScheduler

    init(name: String, number: Int32, state: ActivityState, scheduler: BackgroundTaskScheduler) {
        self.name = name
        self.number = number
        self.state = state
        self.scheduler = scheduler
    }

    deinit {
        end()
    }

    /// Whether time ran out, or the host couldn't give any.
    public var isExpired: Bool {
        state.isExpired
    }

    /// Called when time is up. The activity has ended by then.
    public var onExpiration: (() -> Void)? {
        get { state.onExpiration }
        set { state.onExpiration = newValue }
    }

    /// The work is done. Only the first call counts.
    public func end() {
        guard !state.isEnded else { return }
        state.isEnded = true
        state.onExpiration = nil
        scheduler.ended(number)
    }
}

/// Running the app's code while it isn't in front: `BGTaskScheduler`, for a
/// guest.
///
/// ```swift
/// let scheduler = BackgroundTaskScheduler.shared
/// // In the app's init, at every launch:
/// scheduler.register("org.example.mail.sync") {
///     try await mailbox.fetchNewMessages()
/// }
/// // When there's something to keep fresh:
/// try await scheduler.submit(BackgroundTaskRequest("org.example.mail.sync", every: 30 * 60))
/// ```
///
/// The system starts the app to run a task as it does when the user opens
/// it, with no window: so handlers are registered at launch, before the
/// app's `rt_main` returns.
///
/// It's guest-side only, over the `BackgroundTasks` contract. The guest is
/// single-threaded (§6.4).
public final class BackgroundTaskScheduler: @unchecked Sendable {

    public static let shared = BackgroundTaskScheduler()

    /// The host's tasks, made when first used.
    private var made: (any BackgroundTasks)?

    let events = BackgroundEvents()

    init() { }

    private var tasks: any BackgroundTasks {
        if let made {
            return made
        }
        let tasks = BackgroundTasksProxy.shared()
        made = tasks
        return tasks
    }

    /// Whether the app may run in the background. `denied`: the user turned
    /// it off for this app, in the system's settings. `unavailable`: this
    /// host runs nothing in the background. Nothing prompts for it.
    public var status: PermissionStatus {
        PermissionStatus(rawValue: tasks.status()) ?? .unavailable
    }

    // MARK: Tasks

    /// Says what a task does. Call it in the app's `init`, at every launch.
    /// The handler does the work and calls `complete(success:)`; it sets
    /// `onExpiration` to hear when time is up.
    public func register(_ identifier: String, handler: @escaping (BackgroundTask) -> Void) {
        events.handlers[identifier] = handler
        // Said again with each handler: there are few, and a host that
        // started over would otherwise never hear of them.
        events.isListening = true
        events.scheduler = self
        tasks.setDelegate(events)
    }

    /// Forgets what a task does. Its runs fail from here on.
    public func unregister(_ identifier: String) {
        events.handlers[identifier] = nil
    }

    /// Whether a handler is registered for a task.
    public func isRegistered(_ identifier: String) -> Bool {
        events.handlers[identifier] != nil
    }

    /// Asks the system to run a task: no sooner than the request says, and
    /// when it thinks best. A request replaces the one before with the same
    /// identifier. Fails with `notRegistered` when the task has no handler,
    /// since its runs would all fail.
    public func submit(_ request: BackgroundTaskRequest, completion: @escaping (Result<Void, BackgroundError>) -> Void) {
        guard events.handlers[request.identifier] != nil else {
            completion(.failure(.notRegistered))
            return
        }
        tasks.submit(request.identifier, kind: request.kind.rawValue, earliest: request.earliest, interval: request.every ?? 0,
                     requirements: request.requirements.rawValue, callback: Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Withdraws a request. A run that has started goes on.
    public func cancel(_ identifier: String) {
        tasks.cancel(identifier)
    }

    public func cancelAll() {
        tasks.cancelAll()
    }

    /// The identifiers asked for and not cancelled.
    public func pendingIdentifiers(completion: @escaping (Result<[String], BackgroundError>) -> Void) {
        tasks.pending(Receiver { outcome in
            if case .list(let identifiers) = outcome {
                completion(.success(identifiers))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Activities

    /// Asks for time to finish something: a save, as the user leaves. It
    /// never fails: where the host can't keep the app running, the
    /// activity has expired already.
    public func beginActivity(_ name: String) -> BackgroundActivity {
        let number = tasks.beginActivity(name)
        let state = ActivityState(isExpired: number == 0)
        state.isEnded = number == 0
        if number != 0 {
            events.activities[number] = state
            // To hear if its time runs out.
            events.isListening = true
            events.scheduler = self
            tasks.setDelegate(events)
        }
        return BackgroundActivity(name: name, number: number, state: state, scheduler: self)
    }

    func ended(_ number: Int32) {
        guard events.activities.removeValue(forKey: number) != nil else { return }
        tasks.endActivity(number)
    }

    /// Seconds before the host stops the app, where it knows and there's a
    /// limit.
    public var timeRemaining: Double? {
        let seconds = tasks.timeRemaining()
        return seconds < 0 ? nil : seconds
    }

    // MARK: Async

    #if !EMBEDDED_NO_CONCURRENCY
    /// Says what a task does, as an `async` operation: done when it
    /// returns, failed when it throws. When time is up its task is
    /// cancelled, and it should return quickly.
    public func register<Failure: Error>(
        _ identifier: String,
        operation: nonisolated(nonsending) @escaping () async throws(Failure) -> Void
    ) {
        register(identifier) { (task: BackgroundTask) in
            let work = guestTask { () async -> Bool in
                do throws(Failure) {
                    try await operation()
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
            task.onExpiration = { work.cancel() }
            _ = guestTask {
                task.complete(success: await work.value)
            }
        }
    }

    /// Asks the system to run a task.
    public nonisolated(nonsending) func submit(_ request: BackgroundTaskRequest) async throws(BackgroundError) {
        try await wait { self.submit(request, completion: $0) }
    }

    /// The identifiers asked for and not cancelled.
    public nonisolated(nonsending) func pendingIdentifiers() async throws(BackgroundError) -> [String] {
        try await wait { self.pendingIdentifiers(completion: $0) }
    }

    /// Runs `operation` with an activity around it, ended when it returns
    /// or throws. When time is up its task is cancelled.
    public nonisolated(nonsending) func withActivity<Value: Sendable, Failure: Error>(
        _ name: String,
        operation: nonisolated(nonsending) @escaping () async throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let activity = beginActivity(name)
        let work = guestTask { () async -> Result<Value, Failure> in
            do throws(Failure) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        activity.onExpiration = { work.cancel() }
        let result = await work.value
        activity.end()
        return try result.get()
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(
        _ start: (@escaping (Result<Value, BackgroundError>) -> Void) -> Void
    ) async throws(BackgroundError) -> Value {
        try await withCallback { (callback: Callback<Value, BackgroundError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

#if !EMBEDDED_NO_CONCURRENCY
/// A task on the guest's one thread (§6.4). In a guest every job runs on
/// the guest's executor. In a host build, where tests run this code, the
/// main actor stands for it: Swift's own executor would otherwise run the
/// task on another thread.
func guestTask<Value: Sendable>(_ body: nonisolated(nonsending) @escaping () async -> Value) -> Task<Value, Never> {
    let body = GuestOnly(value: body)
    #if hasFeature(Embedded)
    return Task { await body.value() }
    #else
    return Task { @MainActor in await body.value() }
    #endif
}

/// Hands a value to a task. The guest is single-threaded (§6.4), so the
/// task runs on the same thread as everything else.
struct GuestOnly<Value>: @unchecked Sendable {
    let value: Value
}
#endif

/// The delegate behind the scheduler: runs, and time running out.
final class BackgroundEvents: BackgroundTasksDelegate {

    var handlers: [String: (BackgroundTask) -> Void] = [:]

    /// The runs that are open.
    var runs: [Int32: BackgroundTask] = [:]

    /// The activities that are open.
    var activities: [Int32: ActivityState] = [:]

    var isListening = false

    /// The scheduler lives as long as the app does.
    var scheduler: BackgroundTaskScheduler?

    func run(_ identifier: String, run: Int32) {
        let tasks = BackgroundTasksProxy.shared()
        guard let handler = handlers[identifier] else {
            // Nothing says what this task does.
            tasks.complete(run, success: false)
            return
        }
        let task = BackgroundTask(identifier: identifier, run: run, tasks: tasks)
        runs[run] = task
        task.finished = { self.runs[run] = nil }
        handler(task)
    }

    func didExpire(_ run: Int32) {
        runs[run]?.expire()
    }

    func didExpireActivity(_ activity: Int32) {
        // The host has ended it; there's nothing to end.
        guard let state = activities.removeValue(forKey: activity) else { return }
        state.isExpired = true
        state.isEnded = true
        let expired = state.onExpiration
        state.onExpiration = nil
        expired?()
    }
}

/// What a `BackgroundCallback` was told.
enum BackgroundOutcome {

    case complete
    case list([String])
    case failure(BackgroundError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: BackgroundError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
final class Receiver: BackgroundCallback {

    private var finish: ((BackgroundOutcome) -> Void)?

    init(_ finish: @escaping (BackgroundOutcome) -> Void) {
        self.finish = finish
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: BackgroundOutcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didList(_ identifiers: [String]) {
        answer(.list(identifiers))
    }

    func didFail(_ error: Int32) {
        answer(.failure(BackgroundError(rawValue: error) ?? .unknown))
    }
}
