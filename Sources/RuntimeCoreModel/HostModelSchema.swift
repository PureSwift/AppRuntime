import CoreModel
import DynamicCoreModel
import DynamicRuntime

/// A store's model as the guest describes it: the `ModelSchema` contract,
/// building a CoreModel `Model`.
public final class HostModelSchema: ModelSchema {

    private(set) var entities: [HostModelEntity] = []

    public static func make() -> HostModelSchema {
        HostModelSchema()
    }

    public func addEntity(_ name: String) -> any ModelEntity {
        let entity = HostModelEntity(name: name)
        entities.append(entity)
        return entity
    }

    /// The model, or what's wrong with it.
    func model() -> Result<Model, ModelStoreError> {
        func invalid(_ message: String) -> Result<Model, ModelStoreError> {
            .failure(ModelStoreError(.invalidModel, message: message))
        }
        var names = Set<String>()
        for entity in entities {
            guard !entity.name.isEmpty, names.insert(entity.name).inserted else {
                return invalid("entity \"\(entity.name)\" is unnamed or declared twice")
            }
            if let problem = entity.problem {
                return invalid(problem)
            }
        }
        var descriptions = [EntityDescription]()
        for entity in entities {
            for relationship in entity.relationships {
                guard let destination = entities.first(where: { $0.name == relationship.destinationEntity.rawValue }) else {
                    return invalid("\(entity.name).\(relationship.id) points at \(relationship.destinationEntity), which isn't in the model")
                }
                guard destination.relationships.contains(where: { $0.id == relationship.inverseRelationship }) else {
                    return invalid("\(entity.name).\(relationship.id)'s inverse \(relationship.inverseRelationship) isn't a relationship of \(destination.name)")
                }
            }
            descriptions.append(EntityDescription(id: EntityName(rawValue: entity.name), attributes: entity.attributes, relationships: entity.relationships))
        }
        return .success(Model(entities: descriptions))
    }

    /// The indexes asked for, by entity.
    var indexes: [EntityName: [[PropertyKey]]] {
        var indexes = [EntityName: [[PropertyKey]]]()
        for entity in entities where !entity.indexes.isEmpty && !entity.name.isEmpty {
            indexes[EntityName(rawValue: entity.name)] = entity.indexes
        }
        return indexes
    }
}

/// One entity of a model being described: the `ModelEntity` contract.
public final class HostModelEntity: ModelEntity {

    let name: String

    private(set) var attributes: [Attribute] = []

    private(set) var relationships: [Relationship] = []

    private(set) var indexes: [[PropertyKey]] = []

    /// The first thing wrong with what the guest declared.
    private(set) var problem: String?

    private var keys = Set<String>()

    init(name: String) {
        self.name = name
    }

    /// Whether `key` can be a property's: named, and not used yet.
    private func claim(_ key: String) -> Bool {
        guard !key.isEmpty, !key.contains("."), keys.insert(key).inserted else {
            problem = problem ?? "\(name) has a property \"\(key)\" that's unnamed, dotted or declared twice"
            return false
        }
        return true
    }

    public func addAttribute(_ key: String, type: Int32) -> any ModelProperty {
        guard claim(key) else {
            return HostModelProperty(entity: name, key: key, kind: .invalid)
        }
        guard let type = ModelAttributeType(rawValue: type) else {
            problem = problem ?? "\(name).\(key) has a type this host doesn't know"
            return HostModelProperty(entity: name, key: key, kind: .invalid)
        }
        attributes.append(Attribute(id: PropertyKey(rawValue: key), type: type.attributeType))
        return HostModelProperty(entity: name, key: key, kind: .attribute(type))
    }

    public func addRelationship(_ key: String, toMany: Bool, destination: String, inverse: String) -> any ModelProperty {
        guard claim(key) else {
            return HostModelProperty(entity: name, key: key, kind: .invalid)
        }
        guard !destination.isEmpty, !inverse.isEmpty else {
            problem = problem ?? "\(name).\(key) has no destination or no inverse"
            return HostModelProperty(entity: name, key: key, kind: .invalid)
        }
        relationships.append(Relationship(
            id: PropertyKey(rawValue: key),
            type: toMany ? .toMany : .toOne,
            destinationEntity: EntityName(rawValue: destination),
            inverseRelationship: PropertyKey(rawValue: inverse)
        ))
        return HostModelProperty(entity: name, key: key, kind: .relationship(toMany: toMany))
    }

    public func addIndex(_ properties: [any ModelProperty]) {
        var index = [PropertyKey]()
        for property in properties {
            guard let property = HostModelStoreModule.host(property, as: HostModelProperty.self),
                  property.entity == name, property.kind != .invalid else {
                problem = problem ?? "\(name) has an index on a property that isn't its own"
                return
            }
            index.append(PropertyKey(rawValue: property.name))
        }
        if !index.isEmpty {
            indexes.append(index)
        }
    }
}

/// An attribute or relationship of an entity: the `ModelProperty` contract.
public final class HostModelProperty: ModelProperty {

    enum Kind: Equatable {
        case attribute(ModelAttributeType)
        case relationship(toMany: Bool)
        /// Declared wrongly; its schema doesn't open.
        case invalid
    }

    let entity: String

    let name: String

    let kind: Kind

    init(entity: String, key: String, kind: Kind) {
        self.entity = entity
        self.name = key
        self.kind = kind
    }

    public func key() -> String {
        name
    }
}
