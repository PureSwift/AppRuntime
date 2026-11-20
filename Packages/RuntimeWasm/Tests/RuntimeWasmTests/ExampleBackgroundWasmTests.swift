import Foundation
import Testing
import DynamicBackgroundTasks
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeBackgroundTasks
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// A host's scheduler kept in memory: it holds what's asked for, and the
/// test runs a task when the system would.
final class WasmTestScheduler: BackgroundScheduler {

    var status: PermissionStatus = .granted

    var submitted: [HostBackgroundRequest] = []

    var pendingRequests: [String: HostBackgroundRequest] = [:]

    /// Whether the platform can hold the app for a moment's work.
    var holdsActivities = true

    var held: [Int32: String] = [:]

    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) {
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

/// The example background app as App.wasm under WasmKit, with the shared
/// host implementation over a scheduler the test keeps: the guest's
/// `BackgroundTaskScheduler`, the `BackgroundTasks` contract and
/// `HostBackgroundTasks`, end to end, the task's handler awaiting the host
/// on the guest executor. Part of `WasmShimTests`, which is serialized,
/// since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleBackground`; skipped without it.
    static var exampleBackgroundURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleBackground/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleBackgroundURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleBackground"))
    func exampleBackgroundInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let task = "org.pureswift.example.background.refresh"
        let system = WasmTestScheduler()
        HostBackgroundTasks.reset()
        HostBackgroundTasks.scheduler = system
        HostBackgroundTasks.declared = [task: .refresh]
        // The host answers at once, so each effect is there when the call
        // that caused it returns.
        HostBackgroundTasks.deliver = { $0() }
        HostBackgroundTasksModule.register(in: native)
        defer { HostBackgroundTasks.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleBackgroundURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.backgroundTasks])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.background.Tasks" }?.capability == .backgroundTasks)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }

        // The app started as it always does. The renderer has its tree and
        // no window: all a background start is.
        #expect(text("refreshes") == "Never refreshed")
        #expect(text("status") == "Background: on")
        #expect(text("schedule") == "Not scheduled")

        // The system runs the task, and waits for the app's handler: it
        // asks the host something, and completes when that has answered.
        var outcomes: [Bool] = []
        HostBackgroundTasks.start(task) { outcomes.append($0) }
        #expect(outcomes == [true])
        #expect(text("refreshes") == "Refreshed 1 times", "the tree is ready for when the window comes")
        #expect(HostBackgroundTasks.isIdle, "nothing holds the app now")
        HostBackgroundTasks.start("org.pureswift.example.other") { outcomes.append($0) }
        #expect(outcomes == [true, false], "a task the app never said how to do")

        // The user asks for it to be kept fresh.
        try tap("Keep Fresh")
        #expect(system.submitted == [HostBackgroundRequest(identifier: task, kind: .refresh, interval: 900)])
        #expect(text("schedule") == "Scheduled")

        // Each run asks for the next, no sooner than the interval.
        HostBackgroundTasks.start(task) { outcomes.append($0) }
        #expect(outcomes == [true, false, true] && text("refreshes") == "Refreshed 2 times")
        #expect(system.submitted.last == HostBackgroundRequest(identifier: task, kind: .refresh, earliest: 900, interval: 900))
        try tap("Stop")
        #expect(system.pendingRequests.isEmpty && text("schedule") == "Not scheduled")
        HostBackgroundTasks.start(task) { outcomes.append($0) }
        #expect(system.submitted.count == 2, "withdrawn, it isn't asked for again")

        // Time to finish a save: the app is held until it says it's done.
        try tap("Save Later")
        #expect(text("saving") == "Saving…")
        #expect(system.held.values.sorted() == ["Saving"] && !HostBackgroundTasks.isIdle)
        try tap("Saved")
        #expect(text("saving") == "Saved")
        #expect(system.held.isEmpty && HostBackgroundTasks.isIdle)

        // Or until the system's time for it runs out.
        try tap("Save Later")
        let number = try #require(system.held.keys.first)
        HostBackgroundTasks.expireActivity(number)
        #expect(text("saving") == "Ran out of time" && HostBackgroundTasks.isIdle)

        // A platform that holds no app says so at once.
        system.holdsActivities = false
        try tap("Save Later")
        #expect(text("saving") == "No time given")
    }
}
