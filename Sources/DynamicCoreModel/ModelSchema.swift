import DynamicRuntime

/// A store's model, built up before the store is opened:
/// `NSManagedObjectModel`'s place.
@DynamicRuntime("org.pureswift.data.ModelSchema")
public protocol ModelSchema: AnyObject {

    static func make() -> Self

    func addEntity(_ name: String) -> ModelEntity
}

/// One entity of a model: `NSEntityDescription`'s place.
@DynamicRuntime("org.pureswift.data.ModelEntity")
public protocol ModelEntity: AnyObject {

    /// `type` is a `ModelAttributeType` raw value.
    func addAttribute(_ key: String, type: Int32) -> ModelProperty

    func addRelationship(_ key: String, toMany: Bool, destination: String, inverse: String) -> ModelProperty

    /// One property, or several for a compound index. An index changes
    /// speed, never results; a host may ignore one it can't build.
    func addIndex(_ properties: [ModelProperty])
}

/// An attribute or a relationship of an entity. It's how a record's values
/// are named: the guest gets each once, while it builds the schema, and
/// passes the handle from then on, so reading a value doesn't send its name
/// as a string every time.
@DynamicRuntime("org.pureswift.data.ModelProperty")
public protocol ModelProperty: AnyObject {

    func key() -> String
}
