@_exported import CoreModel
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Inserts and deletes to apply together: all of them, or none.
///
/// ```swift
/// var changes = ModelChanges()
/// changes.insert(team.encode())
/// changes.insert(person.encode())
/// changes.delete(Person.entityName, for: "old")
/// try await store.perform(changes)
/// ```
///
/// They're applied in the order they were added.
public struct ModelChanges: Sendable {

    public enum Change: Sendable {
        case insert(ModelData)
        case delete(EntityName, ObjectID)
    }

    public private(set) var changes: [Change] = []

    public init() { }

    public var isEmpty: Bool {
        changes.isEmpty
    }

    /// Inserts the object. Where there's one with its ID already, the
    /// properties `value` has are set and the others are left as they are.
    public mutating func insert(_ value: ModelData) {
        changes.append(.insert(value))
    }

    public mutating func delete(_ entity: EntityName, for id: ObjectID) {
        changes.append(.delete(entity, id))
    }
}

/// The app's model store, kept by the host: CoreModel's `ModelStorage`
/// over the `ModelStore` contracts (§7.9).
///
/// ```swift
/// let store = RuntimeModelStorage("library", model: model)
/// try await store.insert(person.encode())
/// let adults = try await store.results(Person.self, for: request)
/// ```
///
/// Code written against `ModelStorage` runs on it unchanged. What it adds:
/// `results`, a fetch read as it's used; `perform`, several changes applied
/// together; change observers; and a completion-handler form of every call,
/// for code that isn't `async` and for slices built without the concurrency
/// runtime.
///
/// It can be used as soon as it's made: operations wait for the store to
/// open, and fail with what it failed with if it doesn't. Releasing it
/// closes the store, once its pending operations finish.
///
/// It's guest-side only. The guest is single-threaded (§6.4).
public final class RuntimeModelStorage: @unchecked Sendable {

    /// The store's name: one path component, unique within the app.
    public let name: String

    public let model: Model

    /// The host's store; `nil` when it couldn't be asked for.
    private var store: (any ModelStore)?

    /// Why the store can't be used, once that's known.
    private var failure: ModelStoreError?

    private var entities: [EntityName: EntityBinding] = [:]

    private var functions: [String: DatabaseFunction] = [:]

    private var observers: [(id: Int, body: ([EntityName]) -> Void)] = []

    private var nextObserver = 0

    private let delegate = ChangeReceiver()

    private init(name: String, model: Model) {
        self.name = name
        self.model = model
    }

    /// Opens the app's store `name` for `model`, creating it, or migrating
    /// it from the model it was last opened with.
    ///
    /// - Parameters:
    ///   - indexes: What to make fast, by entity: each is one property's
    ///     key, or several for a compound index. They change speed, never
    ///     results.
    ///   - migration: What to do when the stored model can't be migrated.
    ///   - onOpen: Called once the store is open, or with why it isn't.
    public convenience init(
        _ name: String,
        model: Model,
        indexes: [EntityName: [[PropertyKey]]] = [:],
        migration: ModelMigration = .fail,
        onOpen: ((ModelStoreError?) -> Void)? = nil
    ) {
        self.init(name: name, model: model)
        start(indexes: indexes, migration: migration, onOpen: onOpen)
    }

    /// Opens the store, and answers with it once it's open.
    public static func open(
        _ name: String,
        model: Model,
        indexes: [EntityName: [[PropertyKey]]] = [:],
        migration: ModelMigration = .fail,
        completion: @escaping (Result<RuntimeModelStorage, ModelStoreError>) -> Void
    ) {
        let storage = RuntimeModelStorage(name: name, model: model)
        storage.start(indexes: indexes, migration: migration) { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(storage))
            }
        }
    }

    /// Deletes the store `name` and everything in it. Release the storage
    /// that has it open first.
    public static func destroy(_ name: String, completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        ModelStoreProxy.destroy(name, callback: Receiver.completing(completion))
    }

    deinit {
        // The host may hold the delegate for as long as it has the store.
        delegate.storage = nil
    }

    private func start(indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration, onOpen: ((ModelStoreError?) -> Void)?) {
        let schema: any ModelSchema
        do {
            schema = try makeSchema(indexes: indexes)
        } catch {
            failure = error
            onOpen?(error)
            return
        }
        delegate.storage = Unmanaged.passUnretained(self)
        // The host holds the callback, and so this storage, until it answers.
        store = ModelStoreProxy.open(name, schema: schema, migration: migration.rawValue, delegate: delegate, callback: Receiver { outcome in
            if case .complete = outcome {
                onOpen?(nil)
            } else {
                self.failure = outcome.error
                self.store = nil
                onOpen?(outcome.error)
            }
        })
        if failure != nil {
            // A host that answered before `open` returned.
            store = nil
        }
    }

    /// Describes the model to the host, keeping its handles.
    private func makeSchema(indexes: [EntityName: [[PropertyKey]]]) throws(ModelStoreError) -> any ModelSchema {
        let schema = ModelSchemaProxy.make()
        for description in model.entities {
            let entity = schema.addEntity(description.id.rawValue)
            var binding = EntityBinding(description: description, entity: entity)
            for attribute in description.attributes {
                guard let type = ModelAttributeType(attribute.type) else {
                    throw ModelStoreError(.invalidModel, message: "composite attribute " + description.id.rawValue + "." + attribute.id.rawValue)
                }
                let property = entity.addAttribute(attribute.id.rawValue, type: type.rawValue)
                binding.attributes.append(.init(key: attribute.id, type: type, property: property))
                binding.properties[attribute.id] = property
            }
            for relationship in description.relationships {
                let property = entity.addRelationship(
                    relationship.id.rawValue,
                    toMany: relationship.type == .toMany,
                    destination: relationship.destinationEntity.rawValue,
                    inverse: relationship.inverseRelationship.rawValue
                )
                binding.relationships.append(.init(key: relationship.id, toMany: relationship.type == .toMany, property: property))
                binding.properties[relationship.id] = property
            }
            for index in indexes[description.id] ?? [] {
                var properties = [any ModelProperty]()
                for key in index {
                    guard let property = binding.properties[key] else {
                        throw ModelStoreError(.invalidModel, message: "an index on " + description.id.rawValue + "." + key.rawValue + ", which isn't in the model")
                    }
                    properties.append(property)
                }
                if !properties.isEmpty {
                    entity.addIndex(properties)
                }
            }
            entities[description.id] = binding
        }
        for (entity, _) in indexes where entities[entity] == nil {
            throw ModelStoreError(.invalidModel, message: "indexes for " + entity.rawValue + ", which isn't in the model")
        }
        return schema
    }

    /// The host's store and an entity's handles, or why there are none.
    private func target(_ entity: EntityName) -> Result<(store: any ModelStore, entity: EntityBinding), ModelStoreError> {
        guard let store else {
            return .failure(failure ?? ModelStoreError(.unavailable))
        }
        guard let binding = entities[entity] else {
            return .failure(ModelStoreError(.invalidRequest, message: "no entity " + entity.rawValue))
        }
        return .success((store, binding))
    }

    // MARK: Fetching

    /// A fetch as a snapshot that's read as it's used.
    public func records(for request: FetchRequest, completion: @escaping (Result<FetchedRecords, ModelStoreError>) -> Void) {
        let store: any ModelStore
        let entity: EntityBinding
        switch target(request.entity) {
        case .success(let target): (store, entity) = target
        case .failure(let error): return completion(.failure(error))
        }
        if request.usesFunctions {
            // A host can't call the guest's functions for each object, so
            // the whole entity comes here and CoreModel's evaluator, which
            // defines what every host answers, does the rest.
            let functions = self.functions
            store.fetch(ModelFetchProxy.make(request.entity.rawValue), callback: Receiver { outcome in
                guard case .results(let results) = outcome else {
                    return completion(.failure(outcome.error))
                }
                let all = Array(FetchedRecords(results: results, entity: entity))
                completion(.success(FetchedRecords(request.evaluate(all, functions: functions))))
            })
            return
        }
        let fetch: any ModelFetch
        do {
            fetch = try request.makeFetch()
        } catch {
            return completion(.failure(error))
        }
        store.fetch(fetch, callback: Receiver { outcome in
            if case .results(let results) = outcome {
                completion(.success(FetchedRecords(results: results, entity: entity)))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// A fetch as entities, each read and decoded as it's used.
    public func results<T: Entity>(_ type: T.Type, for request: FetchRequest, completion: @escaping (Result<FetchedResults<T>, ModelStoreError>) -> Void) {
        records(for: request) { result in
            switch result {
            case .success(let records): completion(.success(FetchedResults(records)))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    /// Every object the request matches, read before it answers.
    public func fetch(_ fetchRequest: FetchRequest, completion: @escaping (Result<[ModelData], ModelStoreError>) -> Void) {
        records(for: fetchRequest) { result in
            switch result {
            case .success(let records): completion(.success(Array(records)))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    /// The object with that ID, if there's one.
    public func fetch(_ entity: EntityName, for id: ObjectID, completion: @escaping (Result<ModelData?, ModelStoreError>) -> Void) {
        let store: any ModelStore
        let binding: EntityBinding
        switch target(entity) {
        case .success(let target): (store, binding) = target
        case .failure(let error): return completion(.failure(error))
        }
        let fetch = ModelFetchProxy.make(entity.rawValue)
        fetch.setIDs([id.rawValue])
        store.fetch(fetch, callback: Receiver { outcome in
            if case .results(let results) = outcome {
                completion(.success(FetchedRecords(results: results, entity: binding).first))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    public func fetchID(_ fetchRequest: FetchRequest, completion: @escaping (Result<[ObjectID], ModelStoreError>) -> Void) {
        guard !fetchRequest.usesFunctions else {
            return fetch(fetchRequest) { result in
                switch result {
                case .success(let objects): completion(.success(objects.map { $0.id }))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        let store: any ModelStore
        let fetch: any ModelFetch
        switch target(fetchRequest.entity) {
        case .success(let target): store = target.store
        case .failure(let error): return completion(.failure(error))
        }
        do {
            fetch = try fetchRequest.makeFetch()
        } catch {
            return completion(.failure(error))
        }
        store.fetchIDs(fetch, callback: Receiver { outcome in
            if case .ids(let ids) = outcome {
                completion(.success(ids.map { ObjectID(rawValue: $0) }))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    public func count(_ fetchRequest: FetchRequest, completion: @escaping (Result<UInt, ModelStoreError>) -> Void) {
        guard !fetchRequest.usesFunctions else {
            return fetch(fetchRequest) { result in
                switch result {
                case .success(let objects): completion(.success(UInt(objects.count)))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        let store: any ModelStore
        let fetch: any ModelFetch
        switch target(fetchRequest.entity) {
        case .success(let target): store = target.store
        case .failure(let error): return completion(.failure(error))
        }
        do {
            fetch = try fetchRequest.makeFetch()
        } catch {
            return completion(.failure(error))
        }
        store.count(fetch, callback: Receiver { outcome in
            if case .count(let count) = outcome {
                completion(.success(UInt(clamping: count)))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Changing

    /// Applies the changes together: all of them, or, if it fails, none.
    public func perform(_ changes: ModelChanges, completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        guard let store else {
            return completion(.failure(failure ?? ModelStoreError(.unavailable)))
        }
        let batch = ModelBatchProxy.make()
        do throws(ModelStoreError) {
            for change in changes.changes {
                switch change {
                case .insert(let data):
                    guard let entity = entities[data.entity] else {
                        throw ModelStoreError(.invalidRequest, message: "no entity " + data.entity.rawValue)
                    }
                    let record = ModelRecordProxy.make(entity.entity, id: data.id.rawValue)
                    try entity.write(data, to: record)
                    batch.insert(record)
                case .delete(let entity, let id):
                    guard entities[entity] != nil else {
                        throw ModelStoreError(.invalidRequest, message: "no entity " + entity.rawValue)
                    }
                    batch.delete(entity.rawValue, id: id.rawValue)
                }
            }
        } catch {
            return completion(.failure(error))
        }
        store.perform(batch, callback: Receiver.completing(completion))
    }

    public func insert(_ value: ModelData, completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        insert([value], completion: completion)
    }

    /// Inserts the objects together.
    public func insert(_ values: [ModelData], completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        var changes = ModelChanges()
        for value in values {
            changes.insert(value)
        }
        perform(changes, completion: completion)
    }

    public func delete(_ entity: EntityName, for id: ObjectID, completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        delete(entity, for: [id], completion: completion)
    }

    /// Deletes the objects together. Fine if some are gone already.
    public func delete(_ entity: EntityName, for ids: [ObjectID], completion: @escaping (Result<Void, ModelStoreError>) -> Void) {
        var changes = ModelChanges()
        for id in ids {
            changes.delete(entity, for: id)
        }
        perform(changes, completion: completion)
    }

    /// Makes a function available to predicates and sorts. It runs in the
    /// guest: a request that uses one reads its whole entity, so keep such
    /// requests to small entities. Key paths through relationships aren't
    /// followed in them.
    public func register(function: DatabaseFunction) {
        functions[function.name] = function
    }

    // MARK: Changes

    /// Calls `body` after each committed batch, with the entities it
    /// touched: this storage's batches, and those of anything else that has
    /// the store open. Returns what `removeChangeObserver` takes.
    @discardableResult
    public func addChangeObserver(_ body: @escaping ([EntityName]) -> Void) -> Int {
        nextObserver += 1
        observers.append((nextObserver, body))
        return nextObserver
    }

    public func removeChangeObserver(_ observer: Int) {
        observers.removeAll { $0.id == observer }
    }

    fileprivate func didChange(_ entities: [String]) {
        let names = entities.map { EntityName(rawValue: $0) }
        // An observer may add or remove observers; one that was removed by
        // an earlier one isn't called.
        for observer in observers where self.observers.contains(where: { $0.id == observer.id }) {
            observer.body(names)
        }
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4): in host-side Swift, that's the caller's actor, and not a
    // thread of the pool.

    #if !EMBEDDED_NO_CONCURRENCY
    /// Opens the store, and returns once it's open.
    public nonisolated(nonsending) static func open(
        _ name: String,
        model: Model,
        indexes: [EntityName: [[PropertyKey]]] = [:],
        migration: ModelMigration = .fail
    ) async throws(ModelStoreError) -> RuntimeModelStorage {
        try await wait { open(name, model: model, indexes: indexes, migration: migration, completion: $0) }
    }

    /// Deletes the store `name` and everything in it.
    public nonisolated(nonsending) static func destroy(_ name: String) async throws(ModelStoreError) {
        try await wait { destroy(name, completion: $0) }
    }

    /// A fetch as a snapshot that's read as it's used.
    public nonisolated(nonsending) func records(for request: FetchRequest) async throws(ModelStoreError) -> FetchedRecords {
        try await Self.wait { self.records(for: request, completion: $0) }
    }

    /// A fetch as entities, each read and decoded as it's used.
    public nonisolated(nonsending) func results<T: Entity>(_ type: T.Type, for request: FetchRequest) async throws(ModelStoreError) -> FetchedResults<T> {
        FetchedResults(try await records(for: request))
    }

    /// The entity with that ID, if there's one.
    public nonisolated(nonsending) func fetch<T: Entity>(_ type: T.Type, for id: T.ID) async throws(ModelStoreError) -> T? {
        guard let data = try await fetch(T.entityName, for: ObjectID(rawValue: id.description)) else {
            return nil
        }
        do {
            return try T(from: data)
        } catch {
            throw ModelStoreError(.undecodable, message: T.entityName.rawValue + " " + data.id.rawValue)
        }
    }

    public nonisolated(nonsending) func fetch(_ entity: EntityName, for id: ObjectID) async throws(ModelStoreError) -> ModelData? {
        try await Self.wait { self.fetch(entity, for: id, completion: $0) }
    }

    /// Every object the request matches, read before it returns. For a
    /// large result, `results(_:for:)` reads only what's used.
    public nonisolated(nonsending) func fetch(_ fetchRequest: FetchRequest) async throws(ModelStoreError) -> [ModelData] {
        try await Self.wait { self.fetch(fetchRequest, completion: $0) }
    }

    public nonisolated(nonsending) func fetchID(_ fetchRequest: FetchRequest) async throws(ModelStoreError) -> [ObjectID] {
        try await Self.wait { self.fetchID(fetchRequest, completion: $0) }
    }

    public nonisolated(nonsending) func count(_ fetchRequest: FetchRequest) async throws(ModelStoreError) -> UInt {
        try await Self.wait { self.count(fetchRequest, completion: $0) }
    }

    /// Applies the changes together: all of them, or, if it throws, none.
    public nonisolated(nonsending) func perform(_ changes: ModelChanges) async throws(ModelStoreError) {
        try await Self.wait { self.perform(changes, completion: $0) }
    }

    public nonisolated(nonsending) func insert(_ value: ModelData) async throws(ModelStoreError) {
        try await Self.wait { self.insert(value, completion: $0) }
    }

    /// Inserts the objects together.
    public nonisolated(nonsending) func insert(_ values: [ModelData]) async throws(ModelStoreError) {
        try await Self.wait { self.insert(values, completion: $0) }
    }

    public nonisolated(nonsending) func delete(_ entity: EntityName, for id: ObjectID) async throws(ModelStoreError) {
        try await Self.wait { self.delete(entity, for: id, completion: $0) }
    }

    /// Deletes the objects together.
    public nonisolated(nonsending) func delete(_ entity: EntityName, for ids: [ObjectID]) async throws(ModelStoreError) {
        try await Self.wait { self.delete(entity, for: ids, completion: $0) }
    }

    /// The entities each committed batch touched, from now on.
    public var changes: EventStream<[EntityName], Never> {
        EventStream { continuation in
            let observer = addChangeObserver { continuation.yield($0) }
            continuation.onTermination = { self.removeChangeObserver(observer) }
        }
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) static func wait<Value>(_ start: (@escaping (Result<Value, ModelStoreError>) -> Void) -> Void) async throws(ModelStoreError) -> Value {
        try await withCallback { (callback: Callback<Value, ModelStoreError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: ModelStoreError(.cancelled))
        }
    }
    #endif
}

#if !hasFeature(Embedded)
// Embedded Swift can't witness the protocol's untyped `throws` with a
// concrete error, so there the methods are used directly.
extension RuntimeModelStorage: ModelStorage { }
#endif

/// What a `ModelStoreCallback` was told.
private enum Outcome {

    case complete
    case results(any ModelResults)
    case ids([String])
    case count(Int64)
    case failure(ModelStoreError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: ModelStoreError {
        if case .failure(let error) = self {
            return error
        }
        return ModelStoreError(.unknown)
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: ModelStoreCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didComplete`.
    static func completing(_ completion: @escaping (Result<Void, ModelStoreError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didFetch(_ results: any ModelResults) {
        answer(.results(results))
    }

    func didFetchIDs(_ ids: [String]) {
        answer(.ids(ids))
    }

    func didCount(_ count: Int64) {
        answer(.count(count))
    }

    func didFail(_ error: Int32, message: String) {
        answer(.failure(ModelStoreError(rawValue: error, message: message)))
    }
}

/// The store's delegate. It refers to its storage without owning it: the
/// storage owns the host's store, which owns this, and the storage clears
/// the reference when it's released. Embedded Swift has no weak references.
private final class ChangeReceiver: ModelStoreDelegate {

    var storage: Unmanaged<RuntimeModelStorage>?

    func didChange(_ store: any ModelStore, entities: [String]) {
        storage?.takeUnretainedValue().didChange(entities)
    }
}
