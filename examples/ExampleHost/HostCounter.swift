import DynamicRuntime
import ExampleContracts

/// The host's `Counter` implementation, registered with the Swift-registry
/// backend.
public final class HostCounter: Counter {

    private var count: Int64

    private let counterDelegate: any CounterDelegate

    private var labelValue: String?

    private var tagValues: [String] = []

    private var forks: [HostCounter] = []

    // Non-owning: the parent keeps its forks alive, and outlives them in
    // this example. (Embedded Swift has no `weak`.)
    private unowned(unsafe) let parentCounter: HostCounter?

    init(start: Int64, delegate: any CounterDelegate, parent: HostCounter? = nil) {
        self.count = start
        self.counterDelegate = delegate
        self.parentCounter = parent
    }

    public static func make(start: Int64, delegate: any CounterDelegate) -> HostCounter {
        HostCounter(start: start, delegate: delegate)
    }

    public static func describe(_ value: Int64) -> String {
        "Counter(\(value))"
    }

    public func value() -> Int64 {
        count
    }

    public func increment(by amount: Int32) {
        // A synchronous request answered by the guest.
        guard counterDelegate.shouldIncrement(self, by: amount) else { return }
        count += Int64(amount)
        counterDelegate.didChange(self, value: count)
    }

    public func isEven() -> Bool {
        count % 2 == 0
    }

    public func ratio() -> Double {
        Double(count) / 2
    }

    public func scale(_ factor: Float) -> Float {
        Float(count) * factor
    }

    public func label() -> String? {
        labelValue
    }

    public func setLabel(_ label: String?) {
        labelValue = label
    }

    public func tags() -> [String] {
        tagValues
    }

    public func setTags(_ tags: [String]) {
        tagValues = tags
    }

    public func snapshot() -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: count) >> UInt64($0 * 8)) }
    }

    public func restore(_ snapshot: [UInt8]) throws(RuntimeError) {
        guard snapshot.count == 8 else {
            throw RuntimeError.thrown("invalid snapshot")
        }
        var bits: UInt64 = 0
        for (index, byte) in snapshot.enumerated() {
            bits |= UInt64(byte) << UInt64(index * 8)
        }
        count = Int64(bitPattern: bits)
    }

    public func reset() throws {
        count = 0
        counterDelegate.didReset(self)
    }

    public func fork() -> any Counter {
        let child = HostCounter(start: 0, delegate: counterDelegate, parent: self)
        forks.append(child)
        return child
    }

    public func children() -> [any Counter] {
        // Element-wise conversion: Embedded Swift can't upcast arrays.
        forks.map { (fork: HostCounter) -> any Counter in fork }
    }

    public func parent() -> (any Counter)? {
        parentCounter
    }

    public func delegate() -> any CounterDelegate {
        counterDelegate
    }
}
