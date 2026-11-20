import Testing
import DynamicBackgroundTasks
import DynamicRuntime
import RuntimeNative

/// A host's background tasks that only write down what they're asked, and
/// keep each callback for the test to answer.
final class ScriptedTasks: BackgroundTasks {

    nonisolated(unsafe) static let instance = ScriptedTasks()

    var calls: [String] = []

    var callbacks: [any BackgroundCallback] = []

    var delegate: (any BackgroundTasksDelegate)?

    var statusValue: Int32 = PermissionStatus.granted.rawValue

    /// What the next activity is numbered; 0 when the host can't hold the app.
    var nextActivity: Int32 = 100

    var remaining: Double = -1

    static func shared() -> ScriptedTasks { instance }

    func status() -> Int32 { statusValue }

    func setDelegate(_ delegate: (any BackgroundTasksDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }

    func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32, callback: any BackgroundCallback) {
        calls.append("submit \(identifier) \(kind) \(earliest) \(interval) \(requirements)")
        callbacks.append(callback)
    }

    func cancel(_ identifier: String) { calls.append("cancel \(identifier)") }

    func cancelAll() { calls.append("cancelAll") }

    func pending(_ callback: any BackgroundCallback) {
        calls.append("pending")
        callbacks.append(callback)
    }

    func complete(_ run: Int32, success: Bool) { calls.append("complete \(run) \(success)") }

    func beginActivity(_ name: String) -> Int32 {
        calls.append("beginActivity \(name)")
        guard nextActivity != 0 else { return 0 }
        defer { nextActivity += 1 }
        return nextActivity
    }

    func endActivity(_ activity: Int32) { calls.append("endActivity \(activity)") }

    func timeRemaining() -> Double { remaining }
}

/// Counts what a handler was asked to do.
final class Work: @unchecked Sendable {
    var started = 0
    var cancelled = 0
    var fails = false
    var gate: CheckedContinuation<Void, Never>?
}

struct WorkFailed: Error { }

/// Serialized: the tests share the native runtime, the scripted host and
/// the guest's one scheduler.
@Suite(.serialized) struct DynamicBackgroundTasksTests {

    let host = ScriptedTasks.instance

    let scheduler = BackgroundTaskScheduler.shared

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        BackgroundTasksProxy.register(ScriptedTasks.self, in: native)
        BackgroundTasksDelegateProxy.registerInterface(in: native)
        BackgroundCallbackProxy.registerInterface(in: native)
        // The scheduler keeps the host's object it first asked for, so the
        // scripted one is emptied, not replaced.
        for identifier in ["sync", "index", "slow"] {
            scheduler.unregister(identifier)
        }
        host.calls = []
        host.callbacks = []
        host.statusValue = PermissionStatus.granted.rawValue
        host.nextActivity = 100
        host.remaining = -1
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func failure<Value>(_ result: Result<Value, BackgroundError>?) -> BackgroundError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: Contracts

    @Test func theContractRequiresBackgroundTasks() {
        let tasks = BackgroundTasksProxy.descriptor
        #expect(tasks.name == "org.pureswift.background.Tasks")
        #expect(tasks.capability == .backgroundTasks)
        #expect(method(tasks, "shared")?.kind == .constructor)
        #expect(method(tasks, "status")?.signature == Signature("()I"))
        #expect(method(tasks, "submit:kind:earliest:interval:requirements:callback:")?.signature == Signature("(OIDDIO)V"))
        #expect(method(tasks, "complete:success:")?.signature == Signature("(IZ)V"))
        #expect(method(tasks, "beginActivity:")?.signature == Signature("(O)I"), "a number, not an object")
        #expect(method(tasks, "timeRemaining")?.signature == Signature("()D"))
        #expect(tasks.methods.count == 11)

        let delegate = BackgroundTasksDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.background.TasksDelegate" && delegate.kind == .callback)
        #expect(method(delegate, "run:run:")?.signature == Signature("(OI)V"))
        #expect(method(delegate, "didExpire:")?.signature == Signature("(I)V"))
        #expect(method(delegate, "didExpireActivity:")?.signature == Signature("(I)V"))
        let callback = BackgroundCallbackProxy.descriptor
        #expect(method(callback, "didList:")?.signature == Signature("(O)V"))
        let descriptors = [tasks, delegate, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Requests

    @Test func aRequestSaysWhichTaskHowOftenAndWhatItNeeds() {
        scheduler.register("sync") { _ in }
        var result: Result<Void, BackgroundError>?
        scheduler.submit(BackgroundTaskRequest("sync", every: 1800, requiresNetwork: true)) { result = $0 }
        #expect(host.calls.last == "submit sync 0 0.0 1800.0 1")
        #expect(result == nil, "nothing until the host answers")
        host.callbacks[0].didComplete()
        #expect((try? result?.get()) != nil)

        scheduler.register("index") { _ in }
        scheduler.submit(BackgroundTaskRequest("index", kind: .processing, earliest: 3600, requiresNetwork: true, requiresCharging: true)) { result = $0 }
        #expect(host.calls.last == "submit index 1 3600.0 0.0 3", "once, an hour from now at the soonest")
        host.callbacks[1].didFail(BackgroundError.notDeclared.rawValue)
        #expect(failure(result) == .notDeclared)

        scheduler.submit(BackgroundTaskRequest("sync")) { result = $0 }
        host.callbacks[2].didList([])
        host.callbacks[2].didComplete()
        #expect(failure(result) == .unknown, "an answer of the wrong kind; only the first counts")
        scheduler.submit(BackgroundTaskRequest("sync")) { result = $0 }
        host.callbacks[3].didFail(99)
        #expect(failure(result) == .unknown, "an error from a newer host")

        #expect(BackgroundTaskRequest("a").requirements == [])
        #expect(BackgroundTaskRequest("a", requiresCharging: true).requirements == .charging)
        #expect(BackgroundTaskRequest.shortestInterval == 900)
    }

    @Test func aTaskWithNoHandlerIsntAskedFor() {
        var result: Result<Void, BackgroundError>?
        scheduler.submit(BackgroundTaskRequest("sync", every: 1800)) { result = $0 }
        #expect(failure(result) == .notRegistered, "its runs would all fail")
        #expect(!host.calls.contains { $0.hasPrefix("submit") })
        #expect(!scheduler.isRegistered("sync"))
        scheduler.register("sync") { _ in }
        #expect(scheduler.isRegistered("sync"))
    }

    @Test func requestsAreListedAndWithdrawn() {
        var pending: Result<[String], BackgroundError>?
        scheduler.pendingIdentifiers { pending = $0 }
        host.callbacks[0].didList(["sync", "index"])
        #expect(pending == .success(["sync", "index"]))
        scheduler.cancel("sync")
        scheduler.cancelAll()
        #expect(host.calls == ["pending", "cancel sync", "cancelAll"])
    }

    @Test func theStatusIsTheSystemsSwitch() {
        #expect(scheduler.status == .granted)
        host.statusValue = PermissionStatus.denied.rawValue
        #expect(scheduler.status == .denied, "the user turned it off for this app")
        host.statusValue = 42
        #expect(scheduler.status == .unavailable)
    }

    // MARK: Runs

    @Test func aRunReachesItsHandlerAndIsCompletedOnce() {
        var runs: [BackgroundTask] = []
        scheduler.register("sync") { runs.append($0) }
        #expect(host.delegate != nil, "listening from the first handler")
        host.calls = []

        host.delegate?.run("sync", run: 7)
        #expect(runs.count == 1 && runs[0].identifier == "sync")
        #expect(host.calls.isEmpty, "open until the handler says")
        runs[0].complete(success: true)
        runs[0].complete(success: false)
        #expect(host.calls == ["complete 7 true"], "only the first counts")
        #expect(runs[0].isCompleted)

        // A task nobody registered fails at once, so the system isn't kept waiting.
        host.delegate?.run("unheard", run: 8)
        #expect(host.calls.last == "complete 8 false")
        scheduler.unregister("sync")
        host.delegate?.run("sync", run: 9)
        #expect(host.calls.last == "complete 9 false" && runs.count == 1)
    }

    @Test func aRunIsToldWhenItsOutOfTime() {
        var runs: [BackgroundTask] = []
        var stopped = 0
        scheduler.register("sync") { task in
            task.onExpiration = { stopped += 1 }
            runs.append(task)
        }
        host.delegate?.run("sync", run: 1)
        host.delegate?.run("sync", run: 2)
        host.calls = []
        host.delegate?.didExpire(1)
        host.delegate?.didExpire(1)
        #expect(stopped == 1 && runs[0].isExpired && !runs[1].isExpired, "that run, once")
        runs[0].complete(success: false)
        #expect(host.calls == ["complete 1 false"])

        // One that's done has nothing to stop.
        runs[1].complete(success: true)
        host.delegate?.didExpire(2)
        host.delegate?.didExpire(55)
        #expect(stopped == 1 && !runs[1].isExpired)
    }

    // MARK: Activities

    @Test func anActivityHoldsTheAppUntilItEnds() {
        let activity = scheduler.beginActivity("Saving draft")
        #expect(host.calls.contains("beginActivity Saving draft"))
        #expect(activity.name == "Saving draft" && !activity.isExpired)
        host.calls = []
        activity.end()
        activity.end()
        #expect(host.calls == ["endActivity 100"], "ended once")

        // One that's let go of ends too.
        var held: BackgroundActivity? = scheduler.beginActivity("Upload")
        #expect(held != nil)
        host.calls = []
        held = nil
        #expect(host.calls == ["endActivity 101"])

        host.remaining = 27.5
        #expect(scheduler.timeRemaining == 27.5)
        host.remaining = -1
        #expect(scheduler.timeRemaining == nil, "not known, or not limited")
    }

    @Test func anActivityIsToldWhenTimeRunsOut() {
        let activity = scheduler.beginActivity("Upload")
        var expired = 0
        activity.onExpiration = { expired += 1 }
        host.calls = []
        host.delegate?.didExpireActivity(100)
        host.delegate?.didExpireActivity(100)
        #expect(expired == 1 && activity.isExpired)
        activity.end()
        #expect(host.calls.isEmpty, "the host ended it; there's nothing to end")
    }

    @Test func aHostThatCantHoldTheAppGivesAnActivityThatHasExpired() {
        host.nextActivity = 0
        let activity = scheduler.beginActivity("Saving draft")
        #expect(activity.isExpired, "it never fails: the work goes on while the system lets it")
        host.calls = []
        activity.end()
        #expect(host.calls.isEmpty)
    }

    // MARK: Async

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded (§6.4), and so is the native runtime.

    @MainActor @Test func aHandlerCanBeAnAsyncOperation() async {
        let host = self.host
        let work = Work()
        scheduler.register("sync") {
            work.started += 1
            if work.fails { throw WorkFailed() }
        }
        host.calls = []
        host.delegate?.run("sync", run: 1)
        while !host.calls.contains("complete 1 true") {
            await Task.yield()
        }
        #expect(work.started == 1, "done when it returns")

        work.fails = true
        host.delegate?.run("sync", run: 2)
        while !host.calls.contains(where: { $0.hasPrefix("complete 2") }) {
            await Task.yield()
        }
        #expect(host.calls.last == "complete 2 false", "failed when it throws")
    }

    @MainActor @Test func runningOutOfTimeCancelsTheOperation() async {
        let host = self.host
        let work = Work()
        scheduler.register("slow") {
            work.started += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { work.gate = $0 }
            } onCancel: {
                Task { @MainActor in
                    work.cancelled += 1
                    work.gate?.resume()
                    work.gate = nil
                }
            }
        }
        host.calls = []
        host.delegate?.run("slow", run: 3)
        while work.gate == nil {
            await Task.yield()
        }
        #expect(host.calls.isEmpty, "still running")
        host.delegate?.didExpire(3)
        while !host.calls.contains(where: { $0.hasPrefix("complete 3") }) {
            await Task.yield()
        }
        #expect(work.cancelled == 1)
        #expect(host.calls == ["complete 3 false"], "cut short isn't done")
    }

    @MainActor @Test func requestsCanBeAwaitedAndBlocksHeld() async throws {
        let host = self.host
        let scheduler = self.scheduler
        scheduler.register("sync") { _ in }
        let submitting = Task { @MainActor in
            try await scheduler.submit(BackgroundTaskRequest("sync", every: 900))
            return try await scheduler.pendingIdentifiers()
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        host.callbacks[0].didComplete()
        while host.callbacks.count < 2 {
            await Task.yield()
        }
        host.callbacks[1].didList(["sync"])
        #expect(try await submitting.value == ["sync"])

        host.calls = []
        let saved = try await scheduler.withActivity("Saving") { 42 }
        #expect(saved == 42)
        #expect(host.calls == ["beginActivity Saving", "setDelegate", "endActivity 100"],
                "held for as long as the block runs, and listening for its time running out")

        do {
            _ = try await scheduler.withActivity("Failing") { () async throws -> Int in throw WorkFailed() }
            Issue.record("the block threw")
        } catch {
            #expect(error is WorkFailed)
        }
        #expect(host.calls.last == "endActivity 101", "ended when it throws, too")
    }
}
