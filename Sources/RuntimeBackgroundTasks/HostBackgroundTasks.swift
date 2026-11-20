import Dispatch
import DynamicBackgroundTasks
import DynamicFiles
import DynamicRuntime
import RuntimeABI
import RuntimeHost

/// A task the app asked the system to run.
public struct HostBackgroundRequest: Equatable, Sendable {

    public var identifier: String

    public var kind: BackgroundTaskKind

    /// Seconds from now before which it won't run.
    public var earliest: Double

    /// Seconds between runs; 0 for once.
    public var interval: Double

    public var requirements: BackgroundTaskRequirements

    public init(identifier: String, kind: BackgroundTaskKind = .refresh, earliest: Double = 0, interval: Double = 0, requirements: BackgroundTaskRequirements = []) {
        self.identifier = identifier
        self.kind = kind
        self.earliest = earliest
        self.interval = interval
        self.requirements = requirements
    }

    public var repeats: Bool {
        interval > 0
    }
}

/// What runs a host's background work: the part of the `BackgroundTasks`
/// contract that's the platform's own. Everything is called on the main
/// thread, and every completion is called on it, once.
///
/// When the system runs a task, the scheduler calls
/// `HostBackgroundTasks.start(_:completion:)`, and
/// `HostBackgroundTasks.expire(_:)` when its time is up.
public protocol BackgroundScheduler: AnyObject {

    /// Whether the app may run in the background: the system's switch.
    var status: PermissionStatus { get }

    /// Whether the platform runs a repeating request again by itself. Where
    /// it doesn't, `HostBackgroundTasks` asks again as each run starts.
    var repeatsRequests: Bool { get }

    /// Asks the system for a run, replacing a request with the same
    /// identifier. The request has been checked. `nil`: done.
    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void)

    /// `nil`: all of them.
    func cancel(_ identifier: String?)

    func pending(_ completion: @escaping ([String]) -> Void)

    /// Keeps the app running for an activity the guest began; `false` when
    /// the platform can't. The scheduler calls
    /// `HostBackgroundTasks.expireActivity(_:)` with `number` if time runs
    /// out before the guest ends it.
    func beginActivity(_ name: String, number: Int32) -> Bool

    func endActivity(_ number: Int32)

    /// Seconds before the system stops the app; `nil` where it isn't known
    /// or isn't limited.
    var timeRemaining: Double? { get }
}

public extension BackgroundScheduler {

    var repeatsRequests: Bool { false }

    /// Nothing holds the app for a moment's work.
    func beginActivity(_ name: String, number: Int32) -> Bool { false }

    func endActivity(_ number: Int32) { }

    var timeRemaining: Double? { nil }
}

/// The `BackgroundTasks` contract over a host's `BackgroundScheduler`: what
/// every host written in Swift shares.
///
/// It checks each request against the manifest's tasks before the scheduler
/// sees it, numbers runs and activities, counts a run as failed when the
/// app can't be told of it or doesn't finish in time, remembers repeating
/// requests across launches, and says when nothing holds the app.
///
/// ```swift
/// HostBackgroundTasks.scheduler = MyScheduler()
/// HostBackgroundTasks.declared = ["org.example.mail.sync": .refresh]   // RTBackgroundTasks
/// HostBackgroundTasks.requestsFile = hostData + "/background-requests"
/// HostBackgroundTasksModule.register(in: runtime)
///
/// // After `rt_main` has returned, when the system runs a task:
/// let run = HostBackgroundTasks.start("org.example.mail.sync") { success in
///     systemTask.setTaskCompleted(success: success)
/// }
/// // When its time is up:
/// HostBackgroundTasks.expire(run)
/// ```
///
/// Main thread only.
public final class HostBackgroundTasks: BackgroundTasks {

    /// The host's scheduler. Without one, `status` is `unavailable` and a
    /// request fails with `unsupported`.
    nonisolated(unsafe) public static var scheduler: (any BackgroundScheduler)?

    /// The tasks the manifest names, with their kinds: the bundle's
    /// `RTBackgroundTasks`. A request for any other fails with
    /// `notDeclared`.
    nonisolated(unsafe) public static var declared: [String: BackgroundTaskKind] = [:]

    /// Where repeating requests are remembered across launches, for a
    /// scheduler that doesn't repeat them itself: a file of the host's own.
    /// With none, a request repeats only until the app is next stopped.
    nonisolated(unsafe) public static var requestsFile: String? {
        didSet {
            instance.requests = requestsFile.map(Self.load) ?? [:]
        }
    }

    /// Seconds the app has, after it's told a run is out of time, to
    /// complete it. Then the run counts as failed.
    nonisolated(unsafe) public static var gracePeriod: Double = 2

    /// Runs an answer on the main thread, after the call that asked has
    /// returned. The default is the main dispatch queue; a host with a
    /// loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }

    /// Runs something on the main thread after so many seconds.
    nonisolated(unsafe) public static var after: (Double, @escaping @Sendable () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Called when the last run or activity closes: nothing holds the app
    /// in the background, and the platform may stop it.
    nonisolated(unsafe) public static var onIdle: (() -> Void)?

    // One for the life of the process: a guest keeps the one it first
    // asked for.
    nonisolated(unsafe) private static let instance = HostBackgroundTasks()

    private var delegate: (any BackgroundTasksDelegate)?

    /// The runs that are open, with what to tell the system of each.
    private var runs: [Int32: (Bool) -> Void] = [:]

    /// The activities that are open.
    private var activities: Set<Int32> = []

    /// Repeating requests, to ask again as each runs.
    private var requests: [String: HostBackgroundRequest] = [:]

    /// The next run's or activity's number. One is never used twice.
    private var next: Int32 = 1

    init() { }

    public static func shared() -> HostBackgroundTasks {
        instance
    }

    // MARK: Host side

    /// The system is running a task: the guest does its work, and
    /// `completion` hears how it went, once. Call it after `rt_main` has
    /// returned. Returns the run's number, for `expire(_:)`.
    ///
    /// A run fails at once when the guest registered no handlers. A
    /// repeating request is asked for again here, where the scheduler
    /// doesn't repeat by itself.
    @discardableResult
    public static func start(_ identifier: String, completion: @escaping (Bool) -> Void) -> Int32 {
        let tasks = instance
        let run = tasks.next
        tasks.next += 1
        if let request = tasks.requests[identifier], let scheduler, !scheduler.repeatsRequests {
            var again = request
            again.earliest = request.interval
            scheduler.submit(again) { _ in }
        }
        guard let delegate = tasks.delegate else {
            let held = MainThreadHeld(completion)
            deliver { held.take()?(false) }
            return run
        }
        tasks.runs[run] = completion
        delegate.run(identifier, run: run)
        return run
    }

    /// A run is out of time: the guest is told to stop, and has
    /// `gracePeriod` to complete it before it counts as failed.
    public static func expire(_ run: Int32) {
        let tasks = instance
        guard tasks.runs[run] != nil else { return }
        tasks.delegate?.didExpire(run)
        after(gracePeriod) {
            // The main thread's, as everything here is.
            instance.finish(run, success: false)
        }
    }

    /// An activity the guest began is out of time. It has ended.
    public static func expireActivity(_ number: Int32) {
        let tasks = instance
        guard tasks.activities.remove(number) != nil else { return }
        tasks.delegate?.didExpireActivity(number)
        tasks.idleIfNothingIsOpen()
    }

    /// Whether no run or activity is open: nothing holds the app in the
    /// background.
    public static var isIdle: Bool {
        instance.runs.isEmpty && instance.activities.isEmpty
    }

    /// The repeating requests it remembers.
    public static var repeatingRequests: [HostBackgroundRequest] {
        instance.requests.values.sorted { $0.identifier < $1.identifier }
    }

    /// Forgets the scheduler, the delegate and what's open, for tests and
    /// for a host that starts the guest again.
    public static func reset() {
        scheduler = nil
        declared = [:]
        gracePeriod = 2
        onIdle = nil
        requestsFile = nil
        instance.delegate = nil
        instance.runs = [:]
        instance.activities = []
        instance.requests = [:]
    }

    private func finish(_ run: Int32, success: Bool) {
        guard let completion = runs.removeValue(forKey: run) else { return }
        completion(success)
        idleIfNothingIsOpen()
    }

    private func idleIfNothingIsOpen() {
        if runs.isEmpty, activities.isEmpty {
            Self.onIdle?()
        }
    }

    // MARK: Remembering

    private func remember(_ request: HostBackgroundRequest?, for identifier: String) {
        guard requests[identifier] != request else { return }
        requests[identifier] = request
        save()
    }

    private func save() {
        guard let file = Self.requestsFile else { return }
        // A line each: kind, interval, requirements, then the identifier.
        let lines = requests.values.sorted { $0.identifier < $1.identifier }.map { request in
            "\(request.kind.rawValue) \(request.interval) \(request.requirements.rawValue) \(request.identifier)\n"
        }
        // A file that can't be written loses the repeats, not the request.
        try? HostFiles.replace(file: file, with: Array(lines.joined().utf8))
    }

    private static func load(_ file: String) -> [String: HostBackgroundRequest] {
        guard let bytes = (try? HostFiles.contents(ofFile: file)) ?? nil else { return [:] }
        var requests: [String: HostBackgroundRequest] = [:]
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3)
            guard parts.count == 4, let kind = Int32(parts[0]).flatMap(BackgroundTaskKind.init(rawValue:)),
                  let interval = Double(parts[1]), interval > 0, let requirements = Int32(parts[2]) else {
                // A line from another version, or a damaged one.
                continue
            }
            let identifier = String(parts[3])
            requests[identifier] = HostBackgroundRequest(identifier: identifier, kind: kind, interval: interval,
                                                         requirements: BackgroundTaskRequirements(rawValue: requirements))
        }
        return requests
    }

    // MARK: Background tasks

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any BackgroundCallback, _ answer: @escaping (any BackgroundCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    public func status() -> Int32 {
        (Self.scheduler?.status ?? .unavailable).rawValue
    }

    public func setDelegate(_ delegate: (any BackgroundTasksDelegate)?) {
        self.delegate = delegate
    }

    /// Why a request can't be made, when it can't.
    static func problem(_ request: HostBackgroundRequest) -> BackgroundError? {
        guard declared[request.identifier] == request.kind else {
            // Not named, or named as the other kind: the platform was told
            // something else about it.
            return .notDeclared
        }
        guard request.earliest >= 0, request.earliest.isFinite, request.interval.isFinite,
              request.interval == 0 || request.interval >= BackgroundTaskRequest.shortestInterval else {
            return .invalid
        }
        return nil
    }

    public func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32, callback: any BackgroundCallback) {
        guard let kind = BackgroundTaskKind(rawValue: kind) else {
            Self.later(callback) { $0.didFail(BackgroundError.invalid.rawValue) }
            return
        }
        let request = HostBackgroundRequest(identifier: identifier, kind: kind, earliest: earliest, interval: interval,
                                            requirements: BackgroundTaskRequirements(rawValue: requirements))
        if let problem = Self.problem(request) {
            Self.later(callback) { $0.didFail(problem.rawValue) }
            return
        }
        guard let scheduler = Self.scheduler else {
            Self.later(callback) { $0.didFail(BackgroundError.unsupported.rawValue) }
            return
        }
        scheduler.submit(request) { [self] error in
            if error == nil {
                remember(request.repeats ? request : nil, for: identifier)
            }
            Self.later(callback) { callback in
                if let error {
                    callback.didFail(error.rawValue)
                } else {
                    callback.didComplete()
                }
            }
        }
    }

    public func cancel(_ identifier: String) {
        remember(nil, for: identifier)
        Self.scheduler?.cancel(identifier)
    }

    public func cancelAll() {
        if !requests.isEmpty {
            requests = [:]
            save()
        }
        Self.scheduler?.cancel(nil)
    }

    public func pending(_ callback: any BackgroundCallback) {
        guard let scheduler = Self.scheduler else {
            Self.later(callback) { $0.didList([]) }
            return
        }
        scheduler.pending { identifiers in
            Self.later(callback) { $0.didList(identifiers) }
        }
    }

    public func complete(_ run: Int32, success: Bool) {
        finish(run, success: success)
    }

    public func beginActivity(_ name: String) -> Int32 {
        guard let scheduler = Self.scheduler else { return 0 }
        let number = next
        guard scheduler.beginActivity(name, number: number) else { return 0 }
        next += 1
        activities.insert(number)
        return number
    }

    public func endActivity(_ activity: Int32) {
        guard activities.remove(activity) != nil else { return }
        Self.scheduler?.endActivity(activity)
        idleIfNothingIsOpen()
    }

    public func timeRemaining() -> Double {
        Self.scheduler?.timeRemaining ?? -1
    }
}

/// The built-in `Permissions` contract's view of background work: the
/// system's switch, which nothing prompts for.
public final class BackgroundPermission: PermissionProvider {

    public init() { }

    public func status() -> PermissionStatus {
        HostBackgroundTasks.scheduler?.status ?? .unavailable
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        completion(status())
    }
}

/// The background tasks module: the contract and its callbacks.
public enum HostBackgroundTasksModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [BackgroundTasksProxy.descriptor, BackgroundTasksDelegateProxy.descriptor, BackgroundCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        BackgroundTasksProxy.register(HostBackgroundTasks.self, in: registrar)
        BackgroundTasksDelegateProxy.registerInterface(in: registrar)
        BackgroundCallbackProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.backgroundTasks: BackgroundPermission()]
    }
}
