/// A Swift scalar that travels in one wire slot.
public protocol WireScalar {

    /// The wire type code.
    static var wireType: WireType { get }

    /// Decodes the value from a slot.
    init(slot: Slot)

    /// Encodes the value into a slot.
    var slot: Slot { get }
}

extension Bool: WireScalar {

    public static var wireType: WireType { .bool }

    public init(slot: Slot) {
        self = slot & 0xFF != 0
    }

    public var slot: Slot {
        self ? 1 : 0
    }
}

extension Int32: WireScalar {

    public static var wireType: WireType { .int32 }

    public init(slot: Slot) {
        self = Int32(truncatingIfNeeded: slot)
    }

    public var slot: Slot {
        Slot(bitPattern: Int64(self))
    }
}

extension Int64: WireScalar {

    public static var wireType: WireType { .int64 }

    public init(slot: Slot) {
        self = Int64(bitPattern: slot)
    }

    public var slot: Slot {
        Slot(bitPattern: self)
    }
}

extension Float: WireScalar {

    public static var wireType: WireType { .float32 }

    public init(slot: Slot) {
        self = Float(bitPattern: UInt32(truncatingIfNeeded: slot))
    }

    public var slot: Slot {
        Slot(bitPattern)
    }
}

extension Double: WireScalar {

    public static var wireType: WireType { .float64 }

    public init(slot: Slot) {
        self = Double(bitPattern: slot)
    }

    public var slot: Slot {
        bitPattern
    }
}

public extension Slot {

    /// Encodes an object handle.
    init(handle: ObjectHandle) {
        self = Slot(handle)
    }

    /// Decodes an object handle from the low 32 bits.
    var handle: ObjectHandle {
        ObjectHandle(truncatingIfNeeded: self)
    }
}
