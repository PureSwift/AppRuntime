/// One wire slot (`rt_slot`). Every scalar travels in its own 8-byte slot.
public typealias Slot = UInt64

/// Opaque, refcounted reference to a host object (`rt_obj`). `0` is null.
///
/// Handles are not unique per object; compare objects with `rt_same`.
public typealias ObjectHandle = UInt32

/// Resolved class identifier (`rt_class_id`). Never released. `0` is invalid.
public typealias ClassID = UInt32

/// Resolved method identifier (`rt_method_id`). Never released. `0` is invalid.
public typealias MethodID = UInt32

/// Guest-side context passed to `rt_implement` and returned through
/// `rt_dispatch` / `rt_finalize`.
public typealias ContextID = UInt32

/// The rt ABI version this module describes (`RT_ABI_VERSION`).
public let runtimeABIVersion: UInt32 = 1
