/// Method lookup flags (`RT_METHOD_*`).
public enum MethodKind: UInt32, Equatable, Hashable, Sendable {

    /// `RT_METHOD_INSTANCE`: called on a receiver.
    case instance = 0

    /// `RT_METHOD_STATIC`: ObjC class method, Java static, C function.
    case `static` = 1

    /// `RT_METHOD_CTOR`: ObjC alloc + init…, Java `<init>`, C constructor.
    /// The result slot receives a new +1 object.
    case constructor = 2
}

public extension MethodKind {

    /// Whether `rt_call` ignores the target for this kind.
    var ignoresTarget: Bool {
        self != .instance
    }
}
