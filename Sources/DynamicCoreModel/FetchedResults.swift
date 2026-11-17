import CoreModel
import DynamicRuntime

/// What a fetch found, as `ModelData`: a snapshot the host holds, read a
/// record at a time as it's subscripted, and kept once read.
///
/// `count` is known at once, without reading a record. Later writes don't
/// change a snapshot; fetch again, or use a `Query`, to see them. The host
/// keeps the snapshot until the last copy of this value is gone.
public struct FetchedRecords: RandomAccessCollection {

    final class Snapshot {

        /// The host's results; `nil` when the records are the guest's own.
        let results: (any ModelResults)?

        let entity: EntityBinding?

        let count: Int

        /// The records read so far, by index.
        var read: [Int: ModelData] = [:]

        init(results: any ModelResults, entity: EntityBinding) {
            self.results = results
            self.entity = entity
            self.count = Int(results.count())
        }

        init(_ records: [ModelData]) {
            results = nil
            entity = nil
            count = records.count
            for (index, record) in records.enumerated() {
                read[index] = record
            }
        }
    }

    let snapshot: Snapshot

    /// No records.
    public init() {
        snapshot = Snapshot([])
    }

    /// Records the guest already has.
    public init(_ records: [ModelData]) {
        snapshot = Snapshot(records)
    }

    init(results: any ModelResults, entity: EntityBinding) {
        snapshot = Snapshot(results: results, entity: entity)
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int { snapshot.count }

    public subscript(position: Int) -> ModelData {
        precondition(position >= 0 && position < snapshot.count, "Index out of range")
        if let record = snapshot.read[position] {
            return record
        }
        guard let results = snapshot.results, let entity = snapshot.entity else {
            fatalError("A record is missing from its snapshot")
        }
        let record = entity.read(results.record(at: Int32(position)))
        snapshot.read[position] = record
        return record
    }

    /// How many of the records have been read from the host.
    public var readCount: Int {
        snapshot.read.count
    }

    /// Which snapshot this is: the same for copies of one fetch's records.
    public var snapshotIdentity: ObjectIdentifier {
        ObjectIdentifier(snapshot)
    }
}

/// What a fetch found, as entities: a `FetchedRecords` whose elements are
/// decoded as they're subscripted.
///
/// ```swift
/// let adults = try await store.results(Person.self, for: request)
/// adults.count        // known at once
/// adults[0].name      // reads one record
/// ```
///
/// A list that shows twenty rows of ten thousand reads twenty records.
///
/// The subscript stops the app when a record doesn't decode as `Element`:
/// usually an attribute added to the model since the object was stored,
/// which reads as null, and so wants an optional property. `element(at:)`
/// throws instead.
public struct FetchedResults<Element: Entity>: RandomAccessCollection {

    /// The records, undecoded.
    public let records: FetchedRecords

    public init(_ records: FetchedRecords = FetchedRecords()) {
        self.records = records
    }

    public var startIndex: Int { 0 }

    public var endIndex: Int { records.count }

    public subscript(position: Int) -> Element {
        let record = records[position]
        do {
            return try Element(from: record)
        } catch {
            fatalError("The " + record.entity.rawValue + " with ID " + record.id.rawValue + " doesn't decode")
        }
    }

    /// The element at `position`, or the error its record didn't decode
    /// with.
    public func element(at position: Int) throws(ModelDataDecodingError) -> Element {
        try Element(from: records[position])
    }
}

/// An entity of an open store's model: the host's handles for it and its
/// properties, made once when the store is opened.
struct EntityBinding {

    struct AttributeBinding {
        let key: PropertyKey
        let type: ModelAttributeType
        let property: any ModelProperty
    }

    struct RelationshipBinding {
        let key: PropertyKey
        let toMany: Bool
        let property: any ModelProperty
    }

    let description: EntityDescription

    let entity: any ModelEntity

    var attributes: [AttributeBinding] = []

    var relationships: [RelationshipBinding] = []

    var properties: [PropertyKey: any ModelProperty] = [:]

    /// Reads all of a record's values.
    func read(_ record: any ModelRecord) -> ModelData {
        var data = ModelData(entity: description.id, id: ObjectID(rawValue: record.id()))
        for attribute in attributes {
            let property = attribute.property
            let value: ModelValue
            // A null reads as false, 0 or nil, so only those need a second
            // call to tell them from a value.
            switch attribute.type.kind {
            case .bool:
                let read = record.bool(property)
                value = !read && record.isNull(property) ? .null : .bool(read)
            case .integer:
                let read = record.integer(property)
                value = read == 0 && record.isNull(property) ? .null : .integer(read)
            case .double:
                let read = record.double(property)
                value = read == 0 && record.isNull(property) ? .null : .double(read)
            case .string:
                value = record.string(property).map { .string($0) } ?? .null
            case .data:
                value = record.data(property).map { .data($0) } ?? .null
            }
            data.attributes[attribute.key] = value.attributeValue(as: attribute.type) ?? .null
        }
        for relationship in relationships {
            if relationship.toMany {
                data.relationships[relationship.key] = .toMany(record.toMany(relationship.property).map { ObjectID(rawValue: $0) })
            } else if let id = record.toOne(relationship.property) {
                data.relationships[relationship.key] = .toOne(ObjectID(rawValue: id))
            } else {
                data.relationships[relationship.key] = .null
            }
        }
        return data
    }

    /// Fills a record to insert with `data`'s values: the ones it has, and
    /// no others.
    func write(_ data: ModelData, to record: any ModelRecord) throws(ModelStoreError) {
        for (key, value) in data.attributes {
            guard let property = properties[key], description[attribute: key] != nil else {
                throw ModelStoreError(.invalidRequest, message: description.id.rawValue + " has no attribute " + key.rawValue)
            }
            guard let crossing = ModelValue.crossing(value) else {
                throw ModelStoreError(.unsupported, message: "composite attribute " + key.rawValue)
            }
            switch crossing.value {
            case .null: record.setNull(property)
            case .bool(let value): record.setBool(value, for: property)
            case .integer(let value): record.setInteger(value, for: property)
            case .double(let value): record.setDouble(value, for: property)
            case .string(let value): record.setString(value, for: property)
            case .data(let value): record.setData(value, for: property)
            }
        }
        for (key, value) in data.relationships {
            guard let property = properties[key], description[relationship: key] != nil else {
                throw ModelStoreError(.invalidRequest, message: description.id.rawValue + " has no relationship " + key.rawValue)
            }
            switch value {
            case .null: record.setNull(property)
            case .toOne(let id): record.setToOne(id.rawValue, for: property)
            case .toMany(let ids): record.setToMany(ids.map { $0.rawValue }, for: property)
            }
        }
    }
}
