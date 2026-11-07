import RuntimeABI

/// Reads the argument slots of an incoming call (`rt_dispatch` or a static
/// implementation). Object arguments are borrowed (+0).
public struct Arguments {

    private let base: UnsafePointer<Slot>?

    public let count: Int

    private var index = 0

    public init(_ base: UnsafePointer<Slot>?, count: Int) {
        self.base = count > 0 ? base : nil
        self.count = base == nil ? 0 : count
    }

    /// The next raw slot. Reads past the end yield `0`.
    public mutating func next() -> Slot {
        guard let base, index < count else {
            index += 1
            return 0
        }
        defer { index += 1 }
        return base[index]
    }

    public mutating func scalar<T: WireScalar>(_ type: T.Type = T.self) -> T {
        T(slot: next())
    }

    /// The next borrowed handle. `0` for null.
    public mutating func handle() -> ObjectHandle {
        next().handle
    }

    public mutating func string() -> String {
        optionalString() ?? ""
    }

    public mutating func optionalString() -> String? {
        let handle = handle()
        return handle == 0 ? nil : Runtime.string(handle)
    }

    public mutating func bytes() -> [UInt8] {
        optionalBytes() ?? []
    }

    public mutating func optionalBytes() -> [UInt8]? {
        let handle = handle()
        return handle == 0 ? nil : Runtime.bytes(handle)
    }

    public mutating func strings() -> [String] {
        optionalStrings() ?? []
    }

    public mutating func optionalStrings() -> [String]? {
        let handle = handle()
        return handle == 0 ? nil : RuntimeList.strings(handle)
    }

    /// Unpacks a borrowed `List`. `wrap` receives a +1 handle per element.
    public mutating func list<T>(_ wrap: (ObjectHandle) -> T) -> [T] {
        optionalList(wrap) ?? []
    }

    public mutating func optionalList<T>(_ wrap: (ObjectHandle) -> T) -> [T]? {
        let handle = handle()
        return handle == 0 ? nil : RuntimeList.retainedHandles(handle).map(wrap)
    }
}

/// Writes the result slot of an incoming call. Object results must be +1;
/// ownership passes to the caller.
public struct ResultWriter {

    private let base: UnsafeMutablePointer<Slot>?

    public let count: Int

    public init(_ base: UnsafeMutablePointer<Slot>?, count: Int) {
        self.base = count > 0 ? base : nil
        self.count = base == nil ? 0 : count
    }

    /// Writes a raw slot.
    public func set(slot: Slot) {
        guard let base, count > 0 else { return }
        base[0] = slot
    }

    public func set<T: WireScalar>(_ value: T) {
        set(slot: value.slot)
    }

    /// Writes a +1 handle (`0` for null).
    public func set(retained handle: ObjectHandle) {
        guard base != nil, count > 0 else {
            // Nobody can take ownership; don't leak it.
            Runtime.release(handle)
            return
        }
        set(slot: Slot(handle: handle))
    }

    public func set(_ value: String) {
        set(retained: Runtime.makeString(value))
    }

    public func set(_ value: String?) {
        set(retained: value.map(Runtime.makeString) ?? 0)
    }

    public func set(_ value: [UInt8]) {
        set(retained: Runtime.makeBytes(value))
    }

    public func set(_ value: [UInt8]?) {
        set(retained: value.map(Runtime.makeBytes) ?? 0)
    }

    public func set(_ value: [String]) {
        set(retained: RuntimeList.make(strings: value))
    }

    public func set(_ value: [String]?) {
        set(retained: value.map(RuntimeList.make(strings:)) ?? 0)
    }

    /// Writes an array of objects as a `List`. `handle` returns a +1 handle
    /// for each element.
    public func setList<S: Sequence>(_ values: S, _ handle: (S.Element) -> ObjectHandle) {
        set(retained: RuntimeList.make(retainedHandles: values.map(handle)))
    }

    public func setList<S: Sequence>(_ values: S?, _ handle: (S.Element) -> ObjectHandle) {
        if let values {
            setList(values, handle)
        } else {
            set(retained: 0)
        }
    }
}
