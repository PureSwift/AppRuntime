import Foundation
import Testing
import DynamicBackgroundTasks
import DynamicRuntime
import RuntimeHost
import RuntimeNative
@testable import RuntimeBackgroundTasks

/// A host's scheduler kept in memory: it holds what's asked for, and the
/// test says when the system runs a task.
final class TestScheduler: BackgroundScheduler {

    var status: PermissionStatus = .granted

    var repeatsRequests = false

    var submitted: [HostBackgroundRequest] = []

    var pendingRequests: [String: HostBackgroundRequest] = [:]

    var limit = 11

    /// Whether the platform can hold the app for a moment's work.
    var holdsActivities = true

    var held: [Int32: String] = [:]

    var timeRemaining: Double? = 30

    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) {
        guard pendingRequests[request.identifier] != nil || pendingRequests.count < limit else {
            completion(.limitReached)
            return
        }
        submitted.append(request)
        pendingRequests[request.identifier] = request
        completion(nil)
    }

    func cancel(_ identifier: String?) {
        if let identifier {
            pendingRequests[identifier] = nil
        } else {
            pendingRequests = [:]
        }
    }

    func pending(_ completion: @escaping ([String]) -> Void) {
        completion(pendingRequests.keys.sorted())
    }

    func beginActivity(_ name: String, number: Int32) -> Bool {
        guard holdsActivities else { return false }
        held[number] = name
        return true
    }

    func endActivity(_ number: Int32) {
        held[number] = nil
    }
}

/// A scheduler with nothing but requests: the defaults one gets.
final class PlainScheduler: BackgroundScheduler {
    var status: PermissionStatus { .granted }
    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) { completion(nil) }
    func cancel(_ identifier: String?) { }
    func pending(_ completion: @escaping ([String]) -> Void) { completion([]) }
}

/// `HostBackgroundTasks` over a test's scheduler, driven from the guest's
/// `BackgroundTaskScheduler` through the runtime.
///
/// Serialized: `HostBackgroundTasks`, the guest's one scheduler and the
/// native runtime are shared.
@Suite(.serialized) final class RuntimeBackgroundTasksTests {

    let system = TestScheduler()

    let scheduler = BackgroundTaskScheduler.shared

    let directory: URL

    /// What `after` was asked to do later, for the test to do.
    nonisolated(unsafe) static var timers: [(seconds: Double, work: () -> Void)] = []

    init() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        directory = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeBackgroundTasksTests-\(UUID().uuidString)")
        HostBackgroundTasks.reset()
        HostBackgroundTasks.scheduler = system
        HostBackgroundTasks.declared = ["sync": .refresh, "index": .processing]
        HostBackgroundTasks.deliver = { $0() }
        Self.timers = []
        HostBackgroundTasks.after = { seconds, work in Self.timers.append((seconds, work)) }
        HostBackgroundTasksModule.register(in: native)
        for identifier in ["sync", "index", "undeclared"] {
            scheduler.unregister(identifier)
        }
    }

    deinit {
        HostBackgroundTasks.reset()
        try? Foundation.FileManager.default.removeItem(at: directory)
    }

    func failure<Value>(_ result: Result<Value, BackgroundError>?) -> BackgroundError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @discardableResult
    func submit(_ request: BackgroundTaskRequest) -> BackgroundError? {
        var result: Result<Void, BackgroundError>?
        scheduler.submit(request) { result = $0 }
        if case .failure(let error) = result { return error }
        return result == nil ? .unknown : nil
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostBackgroundTasksModule.contracts.map(\.name) == [
            "org.pureswift.background.Tasks", "org.pureswift.background.TasksDelegate", "org.pureswift.background.Callback",
        ])
        let provider = HostBackgroundTasksModule.permissionProviders()[.backgroundTasks]
        #expect(provider?.status() == .granted)
        system.status = .denied
        var asked: PermissionStatus?
        provider?.request { asked = $0 }
        #expect(asked == .denied, "nothing prompts: it's the system's switch")
        #expect(scheduler.status == .denied)
        HostBackgroundTasks.scheduler = nil
        #expect(provider?.status() == .unavailable && scheduler.status == .unavailable)
    }

    // MARK: Requests

    @Test func aRequestIsCheckedAgainstTheManifest() {
        for identifier in ["sync", "index", "undeclared"] {
            scheduler.register(identifier) { _ in }
        }
        #expect(submit(BackgroundTaskRequest("sync", every: 1800, requiresNetwork: true)) == nil)
        #expect(system.submitted == [HostBackgroundRequest(identifier: "sync", kind: .refresh, interval: 1800, requirements: .network)])
        #expect(submit(BackgroundTaskRequest("index", kind: .processing, earliest: 3600, requiresCharging: true)) == nil)
        #expect(system.submitted.last == HostBackgroundRequest(identifier: "index", kind: .processing, earliest: 3600, requirements: .charging))

        #expect(submit(BackgroundTaskRequest("undeclared")) == .notDeclared)
        #expect(submit(BackgroundTaskRequest("sync", kind: .processing)) == .notDeclared, "named, as the other kind")
        #expect(submit(BackgroundTaskRequest("sync", every: 899)) == .invalid, "a quarter of an hour at least")
        #expect(submit(BackgroundTaskRequest("sync", every: 900)) == nil)
        #expect(submit(BackgroundTaskRequest("sync", earliest: -1)) == .invalid)
        #expect(submit(BackgroundTaskRequest("sync", earliest: .infinity)) == .invalid)
        #expect(system.submitted.count == 3)

        var pending: Result<[String], BackgroundError>?
        scheduler.pendingIdentifiers { pending = $0 }
        #expect(pending == .success(["index", "sync"]))
        scheduler.cancel("index")
        scheduler.pendingIdentifiers { pending = $0 }
        #expect(pending == .success(["sync"]))
        scheduler.cancelAll()
        #expect(system.pendingRequests.isEmpty)

        system.limit = 0
        #expect(submit(BackgroundTaskRequest("sync")) == .limitReached)
        HostBackgroundTasks.scheduler = nil
        #expect(submit(BackgroundTaskRequest("sync")) == .unsupported)
        scheduler.pendingIdentifiers { pending = $0 }
        #expect(pending == .success([]))
    }

    // MARK: Runs

    @Test func theSystemRunsATaskAndHearsHowItWent() {
        var runs: [BackgroundTask] = []
        scheduler.register("sync") { runs.append($0) }
        var idle = 0
        HostBackgroundTasks.onIdle = { idle += 1 }

        var outcomes: [Bool] = []
        let first = HostBackgroundTasks.start("sync") { outcomes.append($0) }
        #expect(runs.count == 1 && runs[0].identifier == "sync")
        #expect(!HostBackgroundTasks.isIdle && outcomes.isEmpty, "the app is held while the run is open")
        runs[0].complete(success: true)
        runs[0].complete(success: false)
        #expect(outcomes == [true], "told once")
        #expect(HostBackgroundTasks.isIdle && idle == 1, "and then nothing holds the app")

        let second = HostBackgroundTasks.start("sync") { outcomes.append($0) }
        #expect(second != first, "a number isn't used twice")
        runs[1].complete(success: false)
        #expect(outcomes == [true, false])

        // A task with nothing registered fails, through the guest.
        HostBackgroundTasks.start("index") { outcomes.append($0) }
        #expect(outcomes == [true, false, false] && HostBackgroundTasks.isIdle)
    }

    @Test func aRunThatOverstaysIsCountedAsFailed() {
        var runs: [BackgroundTask] = []
        var stopped = 0
        scheduler.register("sync") { task in
            task.onExpiration = { stopped += 1 }
            runs.append(task)
        }
        var outcomes: [Bool] = []

        // Told it's out of time, it finishes within the grace it's given.
        let prompt = HostBackgroundTasks.start("sync") { outcomes.append($0) }
        HostBackgroundTasks.expire(prompt)
        #expect(stopped == 1 && runs[0].isExpired && outcomes.isEmpty)
        #expect(Self.timers.last?.seconds == 2)
        runs[0].complete(success: true)
        #expect(outcomes == [true])
        Self.timers.removeLast().work()
        #expect(outcomes == [true], "the grace running out changes nothing after that")

        // One that doesn't is failed for it.
        let late = HostBackgroundTasks.start("sync") { outcomes.append($0) }
        HostBackgroundTasks.gracePeriod = 5
        HostBackgroundTasks.expire(late)
        #expect(Self.timers.last?.seconds == 5 && !HostBackgroundTasks.isIdle)
        Self.timers.removeLast().work()
        #expect(outcomes == [true, false] && HostBackgroundTasks.isIdle)
        runs[1].complete(success: true)
        #expect(outcomes == [true, false], "too late to count")

        HostBackgroundTasks.expire(999)
        #expect(Self.timers.isEmpty, "a run that isn't open has no time to run out")
    }

    @Test func aRunBeforeTheAppListensFails() {
        // The app registered nothing by the time rt_main returned.
        var outcome: Bool?
        HostBackgroundTasks.start("sync") { outcome = $0 }
        #expect(outcome == false && HostBackgroundTasks.isIdle)
    }

    // MARK: Repeating

    @Test func aRepeatingRequestIsAskedAgainAsItRuns() {
        scheduler.register("sync") { $0.complete(success: true) }
        scheduler.register("index") { $0.complete(success: true) }
        #expect(submit(BackgroundTaskRequest("sync", earliest: 60, every: 1800, requiresNetwork: true)) == nil)
        #expect(submit(BackgroundTaskRequest("index", kind: .processing)) == nil)
        #expect(system.submitted.count == 2)
        #expect(HostBackgroundTasks.repeatingRequests.map(\.identifier) == ["sync"])

        HostBackgroundTasks.start("sync") { _ in }
        #expect(system.submitted.count == 3)
        #expect(system.submitted.last == HostBackgroundRequest(identifier: "sync", kind: .refresh, earliest: 1800, interval: 1800, requirements: .network),
                "no sooner than its interval from now")
        HostBackgroundTasks.start("index") { _ in }
        #expect(system.submitted.count == 3, "one that runs once isn't asked again")

        // Cancelled, or asked for once, it stops repeating.
        scheduler.cancel("sync")
        HostBackgroundTasks.start("sync") { _ in }
        #expect(system.submitted.count == 3)
        #expect(submit(BackgroundTaskRequest("sync", every: 900)) == nil)
        #expect(submit(BackgroundTaskRequest("sync")) == nil)
        #expect(HostBackgroundTasks.repeatingRequests.isEmpty)

        // A platform that repeats by itself is left to.
        #expect(submit(BackgroundTaskRequest("sync", every: 900)) == nil)
        system.repeatsRequests = true
        let before = system.submitted.count
        HostBackgroundTasks.start("sync") { _ in }
        #expect(system.submitted.count == before)
    }

    @Test func repeatingRequestsAreRememberedAcrossLaunches() throws {
        let file = directory.appendingPathComponent("host/background-requests").path
        HostBackgroundTasks.requestsFile = file
        scheduler.register("sync") { $0.complete(success: true) }
        scheduler.register("index") { $0.complete(success: true) }
        #expect(submit(BackgroundTaskRequest("sync", every: 1800, requiresNetwork: true)) == nil)
        #expect(submit(BackgroundTaskRequest("index", kind: .processing, every: 86_400, requiresCharging: true)) == nil)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "1 86400.0 2 index\n0 1800.0 1 sync\n")

        // The system starts the app again to run the task: a new process.
        HostBackgroundTasks.reset()
        HostBackgroundTasks.scheduler = system
        HostBackgroundTasks.declared = ["sync": .refresh, "index": .processing]
        HostBackgroundTasks.deliver = { $0() }
        #expect(HostBackgroundTasks.repeatingRequests.isEmpty)
        HostBackgroundTasks.requestsFile = file
        #expect(HostBackgroundTasks.repeatingRequests == [
            HostBackgroundRequest(identifier: "index", kind: .processing, interval: 86_400, requirements: .charging),
            HostBackgroundRequest(identifier: "sync", kind: .refresh, interval: 1800, requirements: .network),
        ])
        scheduler.register("sync") { $0.complete(success: true) }
        system.submitted = []
        HostBackgroundTasks.start("sync") { _ in }
        #expect(system.submitted == [HostBackgroundRequest(identifier: "sync", kind: .refresh, earliest: 1800, interval: 1800, requirements: .network)])

        scheduler.cancel("sync")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "1 86400.0 2 index\n")
        scheduler.cancelAll()
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "")

        // A line this version can't read is skipped.
        try "0 1800.0 1 sync\nnonsense\n9 60.0 0 odd\n0 -5 0 never\n".write(toFile: file, atomically: true, encoding: .utf8)
        HostBackgroundTasks.requestsFile = file
        #expect(HostBackgroundTasks.repeatingRequests.map(\.identifier) == ["sync"])
    }

    // MARK: Activities

    @Test func anActivityHoldsTheAppUntilItEndsOrRunsOut() {
        var idle = 0
        HostBackgroundTasks.onIdle = { idle += 1 }
        let saving = scheduler.beginActivity("Saving draft")
        #expect(!saving.isExpired && system.held.values.sorted() == ["Saving draft"])
        #expect(!HostBackgroundTasks.isIdle)
        #expect(scheduler.timeRemaining == 30)
        let uploading = scheduler.beginActivity("Upload")
        saving.end()
        #expect(system.held.values.sorted() == ["Upload"] && idle == 0, "one is still open")

        // The system's time runs out for it.
        var expired = 0
        uploading.onExpiration = { expired += 1 }
        let number = try! #require(system.held.keys.first)
        HostBackgroundTasks.expireActivity(number)
        HostBackgroundTasks.expireActivity(number)
        #expect(expired == 1 && uploading.isExpired)
        #expect(HostBackgroundTasks.isIdle && idle == 1)
        uploading.end()
        #expect(idle == 1, "it had ended")

        // A platform that can't hold the app says so, and the app isn't held.
        system.holdsActivities = false
        let unheld = scheduler.beginActivity("Later")
        #expect(unheld.isExpired && HostBackgroundTasks.isIdle)
        system.timeRemaining = nil
        #expect(scheduler.timeRemaining == nil)
    }

    @Test func aSchedulerWithNoActivitiesGivesNone() {
        HostBackgroundTasks.scheduler = PlainScheduler()
        scheduler.register("sync") { _ in }
        #expect(submit(BackgroundTaskRequest("sync", every: 900)) == nil)
        #expect(scheduler.beginActivity("Saving").isExpired)
        #expect(scheduler.timeRemaining == nil)
        HostBackgroundTasks.scheduler = nil
        #expect(scheduler.beginActivity("Saving").isExpired)
    }

    /// The configuration a host uses: answers on the main dispatch queue,
    /// after the call that asked has returned.
    @MainActor @Test func aGuestAwaitsTheHostsScheduler() async throws {
        HostBackgroundTasks.deliver = { DispatchQueue.main.async(execute: $0) }
        let scheduler = self.scheduler
        var finished = false
        scheduler.register("sync") {
            finished = true
        }
        try await scheduler.submit(BackgroundTaskRequest("sync", every: 900))
        #expect(try await scheduler.pendingIdentifiers() == ["sync"])
        do {
            try await scheduler.submit(BackgroundTaskRequest("sync", every: 5))
            Issue.record("too often")
        } catch {
            #expect(error == .invalid)
        }

        // The system runs it, and waits for the operation to return.
        let outcome: Bool = await withCheckedContinuation { continuation in
            HostBackgroundTasks.start("sync") { continuation.resume(returning: $0) }
        }
        #expect(outcome && finished)
    }
}
