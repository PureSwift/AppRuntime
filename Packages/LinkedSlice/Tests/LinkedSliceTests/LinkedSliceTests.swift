import Testing
import CRuntime
import DynamicRuntime
import ExampleContracts
import ExampleHost
import RuntimeABI
import RuntimeCore
import RuntimeNative

/// `ExampleApp`'s library, linked into a host whose `DynamicRuntime` is
/// built without `GuestExports`: its sealed macOS slice, or its `App.wasm`
/// translated by wasm2c, which must behave the same (see `Package.swift`).
///
/// Linking at all shows the duplicate `rt_dispatch` / `rt_finalize` are
/// gone. The run shows the routing: the app's calls arrive through the C
/// symbols as `native.guest`, while the host's proxies and exports use the
/// direct binding as `native.host`. If the host's exports went through the
/// C symbols, the runtime would dispatch them into the slice.
@Suite(.serialized) struct LinkedSliceTests {

    static var linksExampleApp: Bool {
        #if LINKED_EXAMPLEAPP
        true
        #else
        false
        #endif
    }

    let native = NativeRuntime.shared

    init() {
        native.bindDirectly()
        ExampleHost.lines = []
        ExampleHost.register(in: native)
    }

    @Test(.enabled(if: linksExampleApp, "Link ExampleApp's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleApp() {
        #if LINKED_EXAMPLEAPP
        // The app may not use Bluetooth; the host may.
        native.capabilities = []
        defer { native.capabilities = nil }
        let clock = ManualClock()
        native.runtime.clock = clock
        defer { native.runtime.clock = nil }
        let handles = native.runtime.handleCount

        let status = native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)

        var lines = ExampleHost.lines
        #expect(status == .ok, "\(lines.joined(separator: "\n"))")
        #expect(lines.contains("beacon refused"), "the app's capabilities")
        #expect(Runtime.lookupClass("org.pureswift.example.Beacon") != 0, "the host's")
        // The slice's executor ran the app's tasks before rt_main returned,
        // up to their sleeps.
        #expect(Array(lines.drop { $0 != "done" }) == [
            "done",
            "ok cancel before sleep",
            "async started",
            "ok task value",
        ])
        #expect(clock.pendingCount == 2, "the 1 ms and 1 s sleeps")

        // The 1 ms timer resumes the main task through the slice's
        // rt_dispatch, which cancels the 1 s sleep.
        clock.advance(by: 1_000_000)
        lines = ExampleHost.lines
        #expect(Array(lines.drop { $0 != "ok task value" }.dropFirst()) == [
            "ok sleep",
            "async done",
            "ok cancel while sleeping",
        ])
        clock.advance(by: 1_000_000_000)
        #expect(clock.pendingCount == 0)
        #expect(ExampleHost.lines.filter { $0.hasPrefix("FAIL") } == [])
        // Every proxy, export and temporary was released, on both sides.
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0)
        #endif
    }

    @Test func hostExportsBelongToTheHost() throws {
        let handles = native.runtime.handleCount
        // Counted from here: an app may hold host exports, such as its renderer.
        let exports = Exported.liveCount
        do {
            let delegate = RecordingDelegate()
            let counter = CounterProxy.make(start: 41, delegate: delegate)
            let implementation = try #require(native.runtime.object(for: counter.handle)?.implementation)
            #expect(implementation.guest === native.host)
            #expect(native.swiftObject(for: counter) is HostCounter)

            // The host calls its own export through the runtime, and the
            // callback reaches its own delegate.
            counter.increment(by: 1)
            #expect(delegate.values == [42])
            #expect(Exported.liveCount == exports + 2, "the counter and its delegate")
        }
        #expect(Exported.liveCount == exports)
        #expect(native.runtime.handleCount == handles)
    }
}

final class RecordingDelegate: CounterDelegate {

    var values: [Int64] = []

    func didChange(_ counter: any Counter, value: Int64) {
        values.append(value)
    }

    func shouldIncrement(_ counter: any Counter, by amount: Int32) -> Bool {
        true
    }

    func didReset(_ counter: any Counter) { }
}
