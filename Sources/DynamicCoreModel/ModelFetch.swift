import DynamicRuntime

/// A fetch request: `NSFetchRequest`'s place. It's read when it's handed to
/// a store; changing it afterwards doesn't change that operation.
@DynamicRuntime("org.pureswift.data.ModelFetch")
public protocol ModelFetch: AnyObject {

    static func make(_ entity: String) -> Self

    func setPredicate(_ predicate: ModelPredicate?)

    /// Sorts by `keyPath`, after the sorts already added.
    func addSort(_ keyPath: String, ascending: Bool)

    /// 0: no limit.
    func setLimit(_ limit: Int32)

    func setOffset(_ offset: Int32)

    /// Only the objects with these IDs: a fetch by ID.
    func setIDs(_ ids: [String])
}

/// A predicate: `NSComparisonPredicate` and `NSCompoundPredicate`, and
/// CoreModel's `FetchRequest.Predicate`.
@DynamicRuntime("org.pureswift.data.ModelPredicate")
public protocol ModelPredicate: AnyObject {

    /// `operation` is a `ModelComparison` raw value, `modifier` a
    /// `ModelComparisonModifier` raw value, and `options` a
    /// `ModelComparisonOptions` raw value.
    static func comparison(_ left: ModelExpression, operation: Int32, right: ModelExpression,
                           modifier: Int32, options: Int32) -> Self

    static func and(_ predicates: [ModelPredicate]) -> Self

    static func or(_ predicates: [ModelPredicate]) -> Self

    static func not(_ predicate: ModelPredicate) -> Self

    /// Always true, or always false.
    static func constant(_ value: Bool) -> Self
}

/// One side of a comparison: `NSExpression`'s place. A constant carries its
/// attribute type (a `ModelAttributeType` raw value), so a date isn't taken
/// for a number, or a UUID for a string.
@DynamicRuntime("org.pureswift.data.ModelExpression")
public protocol ModelExpression: AnyObject {

    static func keyPath(_ path: String) -> Self

    static func null() -> Self

    static func bool(_ value: Bool) -> Self

    /// `int16`, `int32` or `int64`.
    static func integer(_ value: Int64, type: Int32) -> Self

    /// `float`, `double`, or `date` as seconds since 1970 UTC.
    static func double(_ value: Double, type: Int32) -> Self

    /// `string`, `uuid` (lowercase, hyphenated), `url`, or `decimal`.
    static func string(_ value: String, type: Int32) -> Self

    static func data(_ value: [UInt8]) -> Self

    /// The ID of a to-one relationship's object.
    static func toOne(_ id: String) -> Self

    /// The IDs of a to-many relationship's objects.
    static func toMany(_ ids: [String]) -> Self

    /// `operation` is a `ModelArithmetic` raw value.
    static func arithmetic(_ left: ModelExpression, operation: Int32, right: ModelExpression) -> Self
}
