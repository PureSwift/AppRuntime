/// The properties read while tracking: per registrar, a mask of indices
/// below 64 and a list of the rest. Used by one task at a time.
final class AccessList: @unchecked Sendable {

    struct Entry {
        let registrar: ObservationRegistrar
        var mask: UInt64 = 0
        var highIndices: [Int] = []
    }

    private(set) var entries: [Entry] = []

    func record(_ registrar: ObservationRegistrar, _ index: Int) {
        let position: Int
        if let existing = entries.firstIndex(where: { $0.registrar === registrar }) {
            position = existing
        } else {
            entries.append(Entry(registrar: registrar))
            position = entries.count - 1
        }
        if index < 64 {
            entries[position].mask |= 1 << UInt64(index)
        } else if !entries[position].highIndices.contains(index) {
            entries[position].highIndices.append(index)
        }
    }

    func merge(_ other: AccessList) {
        for entry in other.entries {
            if entry.mask != 0 {
                for index in 0..<64 where entry.mask & (1 << UInt64(index)) != 0 {
                    record(entry.registrar, index)
                }
            }
            for index in entry.highIndices {
                record(entry.registrar, index)
            }
        }
    }
}

/// Tracks which observable properties a closure reads.
public enum ObservationTracking {

    #if hasFeature(Embedded)
    /// Accesses being recorded, innermost last. One global stack: the guest
    /// is single-threaded (§6.4), and this works without concurrency.
    nonisolated(unsafe) private static var stack: [AccessList] = []
    #else
    /// Per task in host builds, whose tests run in parallel.
    @TaskLocal private static var stack: [AccessList] = []
    #endif

    static var current: AccessList? {
        stack.last
    }

    /// Runs `body`, returning what it read. Nested tracking also counts
    /// toward the enclosing one.
    static func record<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure) -> (Value, AccessList) {
        let accesses = AccessList()
        #if hasFeature(Embedded)
        stack.append(accesses)
        defer {
            stack.removeLast()
            stack.last?.merge(accesses)
        }
        let value = try body()
        #else
        let result: Result<Value, Failure> = $stack.withValue(stack + [accesses]) {
            Result { () throws(Failure) -> Value in try body() }
        }
        stack.last?.merge(accesses)
        let value = try result.get()
        #endif
        return (value, accesses)
    }

    /// A persistent observer: `track` records what a closure reads, and the
    /// listener calls its handler when any of it changes, until the next
    /// `track` replaces what it watches.
    ///
    /// With coalescing, the handler runs once per `track`, however many
    /// changes follow, which suits "this view is dirty". Without it, it runs
    /// on every change. The handler runs before the change is applied, like
    /// `withObservationTracking`'s.
    public final class Listener {

        private let coalescing: Bool

        private let onChange: () -> Void

        private var observer: Observer?

        /// Whether something changed since the last `track`.
        public private(set) var hasPendingChange = false

        public init(coalescing: Bool = true, onChange: @escaping () -> Void) {
            self.coalescing = coalescing
            self.onChange = onChange
        }

        deinit {
            observer?.cancel()
        }

        /// Runs `body` and watches what it reads, instead of what the last
        /// `track` read.
        public func track<Result, Failure: Error>(_ body: () throws(Failure) -> Result) throws(Failure) -> Result {
            observer?.cancel()
            observer = nil
            hasPendingChange = false
            let (result, accesses) = try ObservationTracking.record(body)
            let observer = Observer(oneShot: false) { [unowned(unsafe) self] in
                self.changed()
            }
            observer.observe(accesses)
            self.observer = observer
            return result
        }

        /// Stops watching.
        public func cancel() {
            observer?.cancel()
            observer = nil
        }

        private func changed() {
            if coalescing && hasPendingChange {
                return
            }
            hasPendingChange = true
            onChange()
        }
    }
}

/// Runs `apply`, and calls `onChange` once, before the first change to any
/// observable property `apply` read.
public func withObservationTracking<T>(
    _ apply: () -> T,
    onChange: @autoclosure () -> @Sendable () -> Void
) -> T {
    let (result, accesses) = ObservationTracking.record(apply)
    let observer = Observer(oneShot: true, onChange: onChange())
    observer.observe(accesses)
    return result
}
