import CoreModel
import DynamicCoreModel

/// Stores kept in memory, for as long as the provider is: for tests, and
/// for a host with nowhere to keep them yet. It follows the migration
/// rules a real provider does.
public actor InMemoryModelStorageProvider: ModelStorageProvider {

    private var stores: [String: (model: Model, storage: InMemoryModelStorage)] = [:]

    public init() { }

    /// The storage behind an open store, for a test to look into.
    public func storage(_ name: String) -> InMemoryModelStorage? {
        stores[name]?.storage
    }

    public func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration) async throws -> any ModelStorage {
        guard let existing = stores[name] else {
            let storage = InMemoryModelStorage(model: model)
            stores[name] = (model, storage)
            return storage
        }
        if Self.canonical(existing.model) == Self.canonical(model) {
            return existing.storage
        }
        let storage = InMemoryModelStorage(model: model)
        if Self.canMigrate(from: existing.model, to: model) {
            // What both models have is carried over; the rest is dropped.
            for entity in model.entities where existing.model[entity.id] != nil {
                for var object in try await existing.storage.fetch(FetchRequest(entity: entity.id)) {
                    object.attributes = object.attributes.filter { entity[attribute: $0.key] != nil }
                    object.relationships = object.relationships.filter { entity[relationship: $0.key] != nil }
                    try await storage.insert(object)
                }
            }
        } else if migration == .fail {
            throw ModelStoreError(.migrationRequired, message: "the store \(name) was made with another model")
        }
        stores[name] = (model, storage)
        return storage
    }

    public func destroy(_ name: String) async throws {
        stores[name] = nil
    }

    /// A model with its entities and properties in one order, so two that
    /// say the same thing are equal.
    static func canonical(_ model: Model) -> Model {
        Model(entities: model.entities
            .map { entity in
                EntityDescription(
                    id: entity.id,
                    attributes: entity.attributes.sorted { $0.id.rawValue < $1.id.rawValue },
                    relationships: entity.relationships.sorted { $0.id.rawValue < $1.id.rawValue }
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue })
    }

    /// Whether everything the two models share is the same in both: only
    /// then can a store's objects be read as the new model's.
    public static func canMigrate(from old: Model, to new: Model) -> Bool {
        for entity in new.entities {
            guard let before = old[entity.id] else { continue }
            for attribute in entity.attributes {
                if let was = before[attribute: attribute.id], was.type != attribute.type {
                    return false
                }
                if before[relationship: attribute.id] != nil {
                    return false
                }
            }
            for relationship in entity.relationships {
                if let was = before[relationship: relationship.id],
                   was.type != relationship.type || was.destinationEntity != relationship.destinationEntity {
                    return false
                }
                if before[attribute: relationship.id] != nil {
                    return false
                }
            }
        }
        return true
    }
}
