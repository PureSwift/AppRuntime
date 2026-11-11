import RuntimeABI

/// Builds the argument slots for one `rt_call` and invokes it.
///
/// Objects created only to pass an argument (strings, byte buffers, lists,
/// exported callbacks) are temporaries: the callee borrows them (+0), and the
/// call releases them once it returns.
public struct Call {

    public let method: MethodReference

    public let target: ObjectHandle

    public private(set) var slots: [Slot] = []

    private var temporaries: [ObjectHandle] = []

    public init(_ method: MethodReference, target: ObjectHandle = 0) {
        self.method = method
        self.target = target
    }

    // MARK: Arguments

    public mutating func add<T: WireScalar>(_ value: T) {
        slots.append(value.slot)
    }

    /// Adds a borrowed object handle (`0` for null).
    public mutating func add(handle: ObjectHandle) {
        slots.append(Slot(handle: handle))
    }

    /// Adds a +1 handle that is released after the call.
    public mutating func add(retained handle: ObjectHandle) {
        slots.append(Slot(handle: handle))
        if handle != 0 {
            temporaries.append(handle)
        }
    }

    public mutating func add(_ value: String) {
        add(retained: Runtime.makeString(value))
    }

    public mutating func add(_ value: String?) {
        add(retained: value.map(Runtime.makeString) ?? 0)
    }

    public mutating func add(_ value: [UInt8]) {
        add(retained: Runtime.makeBytes(value))
    }

    public mutating func add(_ value: [UInt8]?) {
        add(retained: value.map(Runtime.makeBytes) ?? 0)
    }

    public mutating func add(_ value: [String]) {
        add(retained: RuntimeList.make(strings: value))
    }

    public mutating func add(_ value: [String]?) {
        add(retained: value.map(RuntimeList.make(strings:)) ?? 0)
    }

    /// Adds an array of objects as a `List`. `handle` returns a +1 handle for
    /// each element.
    public mutating func addList<S: Sequence>(_ values: S, _ handle: (S.Element) -> ObjectHandle) {
        add(retained: RuntimeList.make(retainedHandles: values.map(handle)))
    }

    /// Adds an optional array of objects as a `List`, or null.
    public mutating func addList<S: Sequence>(_ values: S?, _ handle: (S.Element) -> ObjectHandle) {
        if let values {
            addList(values, handle)
        } else {
            add(handle: 0)
        }
    }

    // MARK: Invoke

    /// Invokes the method and throws on failure.
    public consuming func invoke() throws(RuntimeError) -> Results {
        let (status, results) = perform()
        if let error = Runtime.error(for: status) {
            throw error
        }
        return results
    }

    /// Invokes a method from a non-throwing contract requirement. Traps on
    /// failure, since the requirement has no way to report it.
    public consuming func invokeOrTrap() -> Results {
        let key = method.key
        let (status, results) = perform()
        if status != .ok {
            let message = status == .thrown ? Runtime.takeErrorMessage() : ""
            fatalError("rt_call \(key) failed (status \(status.rawValue)) \(message)")
        }
        return results
    }

    private consuming func perform() -> (RuntimeStatus, Results) {
        let id = method.id
        guard id != 0 else {
            releaseTemporaries()
            return (.notFound, Results(slots: []))
        }
        var results = [Slot](repeating: 0, count: resultCount)
        let status = Runtime.call(target, id, arguments: slots, results: &results)
        releaseTemporaries()
        return (status, Results(slots: status == .ok ? results : []))
    }

    private var resultCount: Int {
        // The last byte of a signature literal is the return type.
        let signature = method.signature
        let last = signature.utf8Start[signature.utf8CodeUnitCount - 1]
        return last == WireType.void.rawValue ? 0 : 1
    }

    private func releaseTemporaries() {
        for handle in temporaries {
            Runtime.release(handle)
        }
    }
}

/// The result slots of a successful call. Object results are +1, and each
/// accessor takes ownership of them.
public struct Results {

    public let slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }

    private var first: Slot {
        slots.first ?? 0
    }

    public func scalar<T: WireScalar>(_ type: T.Type = T.self) -> T {
        T(slot: first)
    }

    /// The returned +1 handle, owned by the caller. `0` for null.
    public func handle() -> ObjectHandle {
        first.handle
    }

    public func string() -> String {
        optionalString() ?? ""
    }

    public func optionalString() -> String? {
        let handle = handle()
        guard handle != 0 else { return nil }
        defer { Runtime.release(handle) }
        return Runtime.string(handle)
    }

    public func bytes() -> [UInt8] {
        optionalBytes() ?? []
    }

    public func optionalBytes() -> [UInt8]? {
        let handle = handle()
        guard handle != 0 else { return nil }
        defer { Runtime.release(handle) }
        return Runtime.bytes(handle)
    }

    public func strings() -> [String] {
        optionalStrings() ?? []
    }

    public func optionalStrings() -> [String]? {
        let handle = handle()
        guard handle != 0 else { return nil }
        defer { Runtime.release(handle) }
        return RuntimeList.strings(handle)
    }

    /// Unpacks a returned `List`. `wrap` receives a +1 handle per element and
    /// owns it even if it throws.
    public func list<T, E: Error>(_ wrap: (ObjectHandle) throws(E) -> T) throws(E) -> [T] {
        try optionalList(wrap) ?? []
    }

    public func optionalList<T, E: Error>(_ wrap: (ObjectHandle) throws(E) -> T) throws(E) -> [T]? {
        let handle = handle()
        guard handle != 0 else { return nil }
        defer { Runtime.release(handle) }
        return try RuntimeList.elements(handle, wrap)
    }
}
