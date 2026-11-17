import CoreModel
import DynamicCoreModel
import DynamicRuntime

/// One object's values: the `ModelRecord` contract, holding a CoreModel
/// `ModelData`.
public final class HostModelRecord: ModelRecord {

    private(set) var data: ModelData?

    /// A fetched record, which its setters leave alone.
    let isFetched: Bool

    /// The first thing wrong with what the guest set. A batch with such a
    /// record fails.
    private(set) var problem: String?

    /// A fetched record.
    init(fetched data: ModelData?) {
        self.data = data
        isFetched = true
    }

    private init(entity: String, id: String) {
        isFetched = false
        if entity.isEmpty {
            problem = "a record of no entity"
        } else {
            data = ModelData(entity: EntityName(rawValue: entity), id: ObjectID(rawValue: id))
        }
    }

    public static func make(_ entity: any ModelEntity, id: String) -> HostModelRecord {
        guard let entity = HostModelStoreModule.host(entity, as: HostModelEntity.self) else {
            return HostModelRecord(entity: "", id: id)
        }
        return HostModelRecord(entity: entity.name, id: id)
    }

    public func id() -> String {
        data?.id.rawValue ?? ""
    }

    /// The record's own property behind a handle.
    private func own(_ property: any ModelProperty) -> HostModelProperty? {
        guard let data, let property = HostModelStoreModule.host(property, as: HostModelProperty.self),
              property.entity == data.entity.rawValue, property.kind != .invalid else {
            return nil
        }
        return property
    }

    /// An attribute's value as it crosses; `null` for anything else.
    private func value(_ property: any ModelProperty) -> ModelValue {
        guard let property = own(property), case .attribute = property.kind,
              let value = data?.attributes[PropertyKey(rawValue: property.name)] else {
            return .null
        }
        return ModelValue.crossing(value)?.value ?? .null
    }

    private func relationship(_ property: any ModelProperty) -> RelationshipValue {
        guard let property = own(property), case .relationship = property.kind else {
            return .null
        }
        return data?.relationships[PropertyKey(rawValue: property.name)] ?? .null
    }

    public func isNull(_ property: any ModelProperty) -> Bool {
        guard let own = own(property) else { return true }
        if case .relationship = own.kind {
            return relationship(property) == .null
        }
        return value(property) == .null
    }

    public func bool(_ property: any ModelProperty) -> Bool {
        if case .bool(let value) = value(property) { return value }
        return false
    }

    public func integer(_ property: any ModelProperty) -> Int64 {
        if case .integer(let value) = value(property) { return value }
        return 0
    }

    public func double(_ property: any ModelProperty) -> Double {
        if case .double(let value) = value(property) { return value }
        return 0
    }

    public func string(_ property: any ModelProperty) -> String? {
        if case .string(let value) = value(property) { return value }
        return nil
    }

    public func data(_ property: any ModelProperty) -> [UInt8]? {
        if case .data(let value) = value(property) { return value }
        return nil
    }

    public func toOne(_ property: any ModelProperty) -> String? {
        if case .toOne(let id) = relationship(property) { return id.rawValue }
        return nil
    }

    public func toMany(_ property: any ModelProperty) -> [String] {
        if case .toMany(let ids) = relationship(property) { return ids.map(\.rawValue) }
        return []
    }

    /// Sets an attribute, if the value is one its type can hold.
    private func set(_ value: ModelValue, for property: any ModelProperty) {
        guard !isFetched else { return }
        guard let property = own(property), case .attribute(let type) = property.kind,
              let attribute = value.attributeValue(as: type) else {
            problem = problem ?? "a value for a property that isn't the record's, or isn't of its type"
            return
        }
        data?.attributes[PropertyKey(rawValue: property.name)] = attribute
    }

    private func set(_ value: RelationshipValue, toMany: Bool, for property: any ModelProperty) {
        guard !isFetched else { return }
        guard let property = own(property), property.kind == .relationship(toMany: toMany) else {
            problem = problem ?? "an ID for a property that isn't the record's, or isn't that kind of relationship"
            return
        }
        data?.relationships[PropertyKey(rawValue: property.name)] = value
    }

    public func setNull(_ property: any ModelProperty) {
        guard !isFetched else { return }
        guard let own = own(property) else {
            problem = problem ?? "a null for a property that isn't the record's"
            return
        }
        if case .relationship = own.kind {
            data?.relationships[PropertyKey(rawValue: own.name)] = .null
        } else {
            set(.null, for: property)
        }
    }

    public func setBool(_ value: Bool, for property: any ModelProperty) {
        set(.bool(value), for: property)
    }

    public func setInteger(_ value: Int64, for property: any ModelProperty) {
        set(.integer(value), for: property)
    }

    public func setDouble(_ value: Double, for property: any ModelProperty) {
        set(.double(value), for: property)
    }

    public func setString(_ value: String, for property: any ModelProperty) {
        set(.string(value), for: property)
    }

    public func setData(_ value: [UInt8], for property: any ModelProperty) {
        set(.data(value), for: property)
    }

    public func setToOne(_ id: String?, for property: any ModelProperty) {
        set(id.map { .toOne(ObjectID(rawValue: $0)) } ?? .null, toMany: false, for: property)
    }

    public func setToMany(_ ids: [String], for property: any ModelProperty) {
        set(.toMany(ids.map { ObjectID(rawValue: $0) }), toMany: true, for: property)
    }
}

/// What a fetch found: the `ModelResults` contract, holding the objects in
/// memory.
public final class HostModelResults: ModelResults {

    let objects: [ModelData]

    init(_ objects: [ModelData]) {
        self.objects = objects
    }

    public func count() -> Int32 {
        Int32(clamping: objects.count)
    }

    public func record(at index: Int32) -> any ModelRecord {
        // Out of range, there's a record with nothing in it.
        HostModelRecord(fetched: objects.indices.contains(Int(index)) ? objects[Int(index)] : nil)
    }
}

/// Changes to apply together: the `ModelBatch` contract.
public final class HostModelBatch: ModelBatch {

    private enum Item {
        case insert(HostModelRecord)
        case delete(String, String)
    }

    private var items: [Item] = []

    private var problem: String?

    public static func make() -> HostModelBatch {
        HostModelBatch()
    }

    public func insert(_ record: any ModelRecord) {
        guard let record = HostModelStoreModule.host(record, as: HostModelRecord.self) else {
            problem = problem ?? "a record that isn't this host's"
            return
        }
        items.append(.insert(record))
    }

    public func delete(_ entity: String, id: String) {
        items.append(.delete(entity, id))
    }

    /// The changes as they stand now, checked against `model`, or what's
    /// wrong with them.
    func changes(in model: Model) -> Result<ModelChanges, ModelStoreError> {
        func invalid(_ message: String) -> Result<ModelChanges, ModelStoreError> {
            .failure(ModelStoreError(.invalidRequest, message: message))
        }
        if let problem {
            return invalid(problem)
        }
        var changes = ModelChanges()
        for item in items {
            switch item {
            case .insert(let record):
                if let problem = record.problem {
                    return invalid(problem)
                }
                guard let data = record.data, let entity = model[data.entity] else {
                    return invalid("a record of an entity that isn't in the model")
                }
                // A property of another model's entity of the same name.
                for key in data.attributes.keys where entity[attribute: key] == nil {
                    return invalid("\(entity.id) has no attribute \(key)")
                }
                for key in data.relationships.keys where entity[relationship: key] == nil {
                    return invalid("\(entity.id) has no relationship \(key)")
                }
                changes.insert(data)
            case .delete(let entity, let id):
                guard !entity.isEmpty, model[EntityName(rawValue: entity)] != nil else {
                    return invalid("no entity \"\(entity)\"")
                }
                changes.delete(EntityName(rawValue: entity), for: ObjectID(rawValue: id))
            }
        }
        return .success(changes)
    }
}
