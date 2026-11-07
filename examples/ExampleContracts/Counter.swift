import DynamicRuntime

/// A counter implemented by the host. Exercises every wire type.
@DynamicRuntime("org.pureswift.example.Counter", version: 1)
public protocol Counter: AnyObject {

    /// Constructor.
    static func make(start: Int64, delegate: CounterDelegate) -> Self

    /// Static method.
    static func describe(_ value: Int64) -> String

    func value() -> Int64

    func increment(by amount: Int32)

    func isEven() -> Bool

    func ratio() -> Double

    func scale(_ factor: Float) -> Float

    func label() -> String?

    func setLabel(_ label: String?)

    func tags() -> [String]

    func setTags(_ tags: [String])

    func snapshot() -> [UInt8]

    func restore(_ snapshot: [UInt8]) throws(RuntimeError)

    func reset() throws

    func fork() -> Counter

    func children() -> [Counter]

    func parent() -> Counter?

    func delegate() -> CounterDelegate
}
