import DynamicRuntime
import ExampleContracts
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The example guest app. It builds unchanged as a native slice
/// (`libapp.a`) and as a wasm reactor module; the host links or loads it and
/// calls `rt_main`.
public enum ExampleApp {

    /// Exercises every wire type and both call directions, reporting each
    /// check through the host's `Reporter`. Returns `.ok` if all passed.
    public static func run() -> RuntimeStatus {
        let reporter = ReporterProxy.make()
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            reporter.record((passed ? "ok " : "FAIL ") + name)
            if !passed {
                failures += 1
            }
        }

        let delegate = AppDelegate()
        let counter = CounterProxy.make(start: 5, delegate: delegate)
        check(counter.value() == 5, "constructor and Int64 result")
        check(CounterProxy.describe(7) == "Counter(7)", "static method and String result")

        counter.increment(by: 3)
        check(counter.value() == 8, "Int32 argument")
        check(delegate.changes == [8], "callback from host to guest")
        counter.increment(by: 1000)
        check(counter.value() == 8, "synchronous callback result")

        check(counter.isEven(), "Bool result")
        check(counter.ratio() == 4.0, "Double result")
        check(counter.scale(1.5) == 12.0, "Float argument and result")

        check(counter.label() == nil, "nil String result")
        counter.setLabel("héllo")
        check(counter.label() == "héllo", "String round trip")
        counter.setLabel(nil)
        check(counter.label() == nil, "nil String argument")

        counter.setTags(["a", "b", "c"])
        check(counter.tags() == ["a", "b", "c"], "[String] round trip")

        let snapshot = counter.snapshot()
        check(snapshot.count == 8, "[UInt8] result")
        counter.increment(by: 2)
        do {
            try counter.restore(snapshot)
            check(counter.value() == 8, "[UInt8] argument")
        } catch {
            check(false, "[UInt8] argument")
        }
        do {
            try counter.restore([1])
            check(false, "typed throws")
        } catch {
            check(error == .thrown("invalid snapshot"), "typed throws carries the host message")
        }
        do {
            try counter.reset()
            check(counter.value() == 0 && delegate.resets == 1, "untyped throws and callback")
        } catch {
            check(false, "untyped throws and callback")
        }

        let child = counter.fork()
        check(child.value() == 0, "object result")
        check(counter.children().count == 1, "[Contract] result")
        if let parent = child.parent() as? DynamicObject, let original = counter as DynamicObject? {
            check(parent.isSame(as: original), "identity of a re-exported host object")
        } else {
            check(false, "identity of a re-exported host object")
        }
        check(counter.delegate().shouldIncrement(counter, by: 1), "guest callback object passed back")

        check(CounterProxy.Methods.value.isAvailable, "method availability")
        check(Runtime.lookupClass("org.pureswift.example.Missing") == 0, "missing contract resolves to 0")
        reporter.record("beacon " + (BeaconProxy.isAvailable ? "available" : "refused"))

        #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
        startAsyncChecks()
        #endif

        reporter.record("done")
        return failures == 0 ? .ok : .thrown
    }
}

#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
extension ExampleApp {

    /// Async checks on the guest executor (§5.4). Embedded builds only: in
    /// host tests Swift's own executor would run them on other threads.
    ///
    /// The tasks run after `run()` returns, before `rt_main` returns. Then
    /// the host advances its clock by 1 ms, which finishes them, and by 1 s,
    /// which fires the last timer.
    static func startAsyncChecks() {
        // Cancelled before it first runs: the sleep throws without a timer.
        let early = Task {
            let reporter = ReporterProxy.make()
            do {
                try await RuntimeClock.sleep(nanoseconds: 1_000_000)
                reporter.record("FAIL cancel before sleep")
            } catch {
                reporter.record("ok cancel before sleep")
            }
        }
        early.cancel()

        // Sleeps for 1 s, but the next task cancels it after 1 ms.
        let long = Task {
            let reporter = ReporterProxy.make()
            do {
                try await RuntimeClock.sleep(nanoseconds: 1_000_000_000)
                reporter.record("FAIL cancel while sleeping")
            } catch {
                reporter.record("ok cancel while sleeping")
            }
        }

        Task {
            let reporter = ReporterProxy.make()
            reporter.record("async started")
            let value = await Task { 41 }.value + 1
            reporter.record(value == 42 ? "ok task value" : "FAIL task value")
            do {
                let start = try RuntimeClock.now()
                try await RuntimeClock.sleep(nanoseconds: 1_000_000)
                let elapsed = try RuntimeClock.now() - start
                reporter.record(elapsed >= 1_000_000 ? "ok sleep" : "FAIL sleep \(elapsed)")
            } catch {
                reporter.record("FAIL sleep")
            }
            long.cancel()
            reporter.record("async done")
        }
    }
}
#endif

/// Guest-side implementation of the callback interface.
final class AppDelegate: CounterDelegate {

    var changes: [Int64] = []

    var resets = 0

    func didChange(_ counter: any Counter, value: Int64) {
        changes.append(value)
    }

    func shouldIncrement(_ counter: any Counter, by amount: Int32) -> Bool {
        amount <= 100
    }

    func didReset(_ counter: any Counter) {
        resets += 1
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleAppMain() -> rt_status {
    Runtime.main { ExampleApp.run() }
}
