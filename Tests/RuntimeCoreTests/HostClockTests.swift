import Testing
import RuntimeABI
@testable import RuntimeCore

/// `ManualClock` and the built-in `Clock` contract served by `HostRuntime`.
@Suite struct HostClockTests {

    let runtime = HostRuntime()

    let guest = FakeGuest()

    let clock = ManualClock()

    init() {
        runtime.clock = clock
    }

    func clockClass() -> ClassID {
        runtime.lookupClass(Array(BuiltinContracts.clockName.utf8), guest: guest)
    }

    func method(_ cls: ClassID, _ key: String, _ signature: String, _ kind: MethodKind) -> MethodID {
        runtime.lookupMethod(cls, key: Array(key.utf8), signature: Array(signature.utf8), flags: kind.rawValue)
    }

    func call(_ method: MethodID, _ arguments: [Slot], results count: Int) -> (RuntimeStatus, [Slot]) {
        var results = [Slot](repeating: 0, count: count)
        let status = arguments.withUnsafeBufferPointer { arguments in
            results.withUnsafeMutableBufferPointer { results in
                runtime.call(target: 0, method: method, arguments: arguments, results: results)
            }
        }
        return (status, results)
    }

    /// A guest `ClockDelegate`, as `RuntimeClock.after` exports one.
    func makeDelegate(context: ContextID) -> ObjectHandle {
        let delegateClass = runtime.lookupClass(Array(BuiltinContracts.clockDelegateName.utf8), guest: guest)
        return runtime.implement(
            interfaces: [delegateClass],
            methods: [(Array("fire".utf8), Array("()V".utf8))],
            context: context,
            guest: guest
        )
    }

    // MARK: ManualClock

    @Test func manualClockFiresInDeadlineOrder() {
        let clock = ManualClock(time: 100)
        var fired: [String] = []
        clock.schedule(after: 30) { fired.append("c") }
        clock.schedule(after: 10) { fired.append("a") }
        clock.schedule(after: 10) { fired.append("b") }
        clock.schedule(after: -5) { fired.append("now") }
        #expect(clock.pendingCount == 4)

        clock.advance(by: 9)
        #expect(fired == ["now"])
        #expect(clock.now() == 109)

        clock.advance(by: 100)
        #expect(fired == ["now", "a", "b", "c"], "ties fire in scheduling order")
        #expect(clock.now() == 209)
        #expect(clock.pendingCount == 0)
    }

    @Test func manualClockFiresTimersScheduledWhileFiring() {
        let clock = ManualClock()
        var fired: [Int64] = []
        clock.schedule(after: 10) {
            fired.append(clock.now())
            clock.schedule(after: 10) { fired.append(clock.now()) }
            clock.schedule(after: 100) { fired.append(clock.now()) }
        }
        clock.advance(by: 50)
        #expect(fired == [10, 20], "the time is each timer's deadline")
        #expect(clock.pendingCount == 1)
        #expect(clock.now() == 50)
    }

    // MARK: Clock contract

    @Test func clockIsBuiltIn() {
        let cls = clockClass()
        #expect(cls != 0)
        #expect(method(cls, "now", "()J", .static) != 0)
        #expect(method(cls, "after:delegate:", "(JO)V", .static) != 0)
        #expect(runtime.descriptor(named: BuiltinContracts.clockDelegateName)?.kind == .callback)
    }

    @Test func nowReadsTheHostClock() {
        clock.advance(by: 1_234)
        let (status, results) = call(method(clockClass(), "now", "()J", .static), [], results: 1)
        #expect(status == .ok)
        #expect(Int64(slot: results[0]) == 1_234)
    }

    @Test func afterFiresTheDelegateOnceThenReleasesIt() {
        let after = method(clockClass(), "after:delegate:", "(JO)V", .static)
        let delegate = makeDelegate(context: 7)
        let handles = runtime.handleCount
        let (status, _) = call(after, [Int64(1_000).slot, Slot(handle: delegate)], results: 0)
        #expect(status == .ok)
        // The guest drops its reference; the timer keeps the delegate alive.
        runtime.release(delegate)
        #expect(runtime.handleCount == handles)
        #expect(guest.finalized.isEmpty)

        clock.advance(by: 999)
        #expect(guest.dispatched.isEmpty)
        clock.advance(by: 1)
        #expect(guest.dispatched.map(\.context) == [7])
        #expect(guest.dispatched.map(\.index) == [0])
        #expect(guest.finalized == [7], "released after firing")
        #expect(runtime.handleCount == handles - 1)
    }

    @Test func afterNeedsAClockDelegate() {
        let after = method(clockClass(), "after:delegate:", "(JO)V", .static)
        let string = runtime.makeString("not a delegate")
        #expect(call(after, [Int64(1).slot, Slot(handle: string)], results: 0).0 == .null)
        #expect(call(after, [Int64(1).slot, Slot(handle: 0)], results: 0).0 == .null)
        #expect(clock.pendingCount == 0)
    }

    @Test func clockCallsFailWithoutAHostClock() {
        runtime.clock = nil
        let (status, _) = call(method(clockClass(), "now", "()J", .static), [], results: 1)
        #expect(status == .thrown)
        #expect(String(decoding: runtime.errorMessage(capacity: 1024), as: UTF8.self) == "This host has no clock")
    }
}
