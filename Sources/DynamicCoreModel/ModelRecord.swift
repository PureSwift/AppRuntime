import DynamicRuntime

/// One object's values: `NSManagedObject`'s place, as a value. A fetched
/// record is read-only, and its setters do nothing. A record to insert is
/// made with `make`, filled in, and added to a batch.
///
/// Each attribute type crosses as one of five kinds of value, which is the
/// getter and the setter used for it (see `ModelAttributeType`). A getter
/// of the wrong kind, or of a null value, answers `false`, 0 or `nil`.
@DynamicRuntime("org.pureswift.data.ModelRecord")
public protocol ModelRecord: AnyObject {

    /// A record to insert.
    static func make(_ entity: ModelEntity, id: String) -> Self

    func id() -> String

    func isNull(_ property: ModelProperty) -> Bool

    func bool(_ property: ModelProperty) -> Bool

    func integer(_ property: ModelProperty) -> Int64

    func double(_ property: ModelProperty) -> Double

    func string(_ property: ModelProperty) -> String?

    func data(_ property: ModelProperty) -> [UInt8]?

    /// The ID of the object a to-one relationship points at.
    func toOne(_ property: ModelProperty) -> String?

    func toMany(_ property: ModelProperty) -> [String]

    func setNull(_ property: ModelProperty)

    func setBool(_ value: Bool, for property: ModelProperty)

    func setInteger(_ value: Int64, for property: ModelProperty)

    func setDouble(_ value: Double, for property: ModelProperty)

    func setString(_ value: String, for property: ModelProperty)

    func setData(_ value: [UInt8], for property: ModelProperty)

    func setToOne(_ id: String?, for property: ModelProperty)

    func setToMany(_ ids: [String], for property: ModelProperty)
}

/// What a fetch found: a snapshot the host holds in memory, read by index
/// as it's needed. `count` and `record(at:)` answer at once, without
/// touching storage.
@DynamicRuntime("org.pureswift.data.ModelResults")
public protocol ModelResults: AnyObject {

    func count() -> Int32

    func record(at index: Int32) -> ModelRecord
}

/// Inserts and deletes to apply together. It's read when it's handed to a
/// store.
@DynamicRuntime("org.pureswift.data.ModelBatch")
public protocol ModelBatch: AnyObject {

    static func make() -> Self

    /// Inserts the record. Where there's an object with its ID already,
    /// the properties the record has values for are set, and the object's
    /// others are left as they are: CoreModel's `insert`.
    func insert(_ record: ModelRecord)

    func delete(_ entity: String, id: String)
}
