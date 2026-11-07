import RuntimeABI

/// Base class of every proxy: owns one +1 handle and releases it in `deinit`.
///
/// Generated contract and callback proxies subclass this, so marshaling code
/// can recover the handle from any proxy with a class cast.
open class DynamicObject {

    /// The owned handle. Never `0`.
    public let handle: ObjectHandle

    /// Takes ownership of a +1 handle.
    public init(retained handle: ObjectHandle) {
        precondition(handle != 0, "Unexpected null object")
        self.handle = handle
    }

    /// Retains a borrowed (+0) handle.
    public init(borrowing handle: ObjectHandle) {
        precondition(handle != 0, "Unexpected null object")
        Runtime.retain(handle)
        self.handle = handle
    }

    deinit {
        Runtime.release(handle)
    }

    /// A new +1 reference to the same object, for passing ownership on.
    public var retainedHandle: ObjectHandle {
        Runtime.retain(handle)
        return handle
    }

    /// Identity test through `rt_same`.
    public func isSame(as other: DynamicObject) -> Bool {
        Runtime.same(handle, other.handle)
    }

    /// Type test through `rt_is_instance`.
    public func isInstance(of cls: ClassReference) -> Bool {
        Runtime.isInstance(handle, of: cls.id)
    }
}
