/// The host's time source behind the built-in `Clock` contract (§5.4).
///
/// Set it on `HostRuntime.clock`. The runtime is single-threaded (§6.4), so
/// `schedule` must run `body` on the runtime's thread (the main thread, or
/// whichever thread pumps the host's loop), never earlier than asked.
public protocol HostClock: AnyObject {

    /// Monotonic nanoseconds since an arbitrary start.
    func now() -> Int64

    /// Runs `body` once, after at least `nanoseconds`.
    func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void)
}

/// A clock that moves only when told to: for tests, and for hosts that pump
/// their own loop and know how much time has passed.
public final class ManualClock: HostClock {

    /// Current time in nanoseconds.
    public private(set) var time: Int64

    private var timers: [Timer] = []

    private var nextSequence: UInt64 = 0

    public init(time: Int64 = 0) {
        self.time = time
    }

    /// Timers that haven't fired.
    public var pendingCount: Int {
        timers.count
    }

    public func now() -> Int64 {
        time
    }

    public func schedule(after nanoseconds: Int64, _ body: @escaping () -> Void) {
        let (deadline, overflow) = time.addingReportingOverflow(Swift.max(nanoseconds, 0))
        timers.append(Timer(deadline: overflow ? .max : deadline, sequence: nextSequence, body: body))
        nextSequence &+= 1
    }

    /// Moves time forward, firing every timer that comes due in deadline
    /// order (timers with the same deadline fire in the order they were
    /// scheduled). A timer scheduled while firing also fires if it comes due
    /// in time.
    public func advance(by nanoseconds: Int64) {
        let (target, overflow) = time.addingReportingOverflow(Swift.max(nanoseconds, 0))
        let end = overflow ? Int64.max : target
        while let index = nextDue(by: end) {
            let timer = timers.remove(at: index)
            time = Swift.max(time, timer.deadline)
            timer.body()
        }
        time = end
    }

    private func nextDue(by end: Int64) -> Int? {
        var best: Int?
        for (index, timer) in timers.enumerated() where timer.deadline <= end {
            if let current = best,
               (timers[current].deadline, timers[current].sequence) <= (timer.deadline, timer.sequence) {
                continue
            }
            best = index
        }
        return best
    }

    private struct Timer {
        let deadline: Int64
        let sequence: UInt64
        let body: () -> Void
    }
}
