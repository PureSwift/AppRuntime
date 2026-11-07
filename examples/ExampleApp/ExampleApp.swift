import DynamicRuntime
import ExampleContracts

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

        reporter.record("done")
        return failures == 0 ? .ok : .thrown
    }
}

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
    rt_status(rawValue: ExampleApp.run().rawValue)
}
