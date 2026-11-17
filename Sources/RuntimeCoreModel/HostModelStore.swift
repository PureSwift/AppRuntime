import CoreModel
import Dispatch
import DynamicCoreModel
import DynamicRuntime
import RuntimeABI
import RuntimeHost
import RuntimeNative

/// Where a host's stores are kept: what opens a CoreModel backend for a
/// store's name.
///
/// The Darwin host's opens a `CoreDataModel` container, the Linux host's a
/// CoreModel-SQLite database. `InMemoryModelStorageProvider` keeps nothing,
/// for tests.
///
/// Its methods are called off the main thread, one at a time for a name.
public protocol ModelStorageProvider: Sendable {

    /// Opens the store `name` for `model`, creating it, or migrating it
    /// from the model it was last opened with (§7.9):
    ///
    /// - added or removed entities and properties migrate by themselves;
    /// - an attribute's type, or a relationship's destination or kind,
    ///   can't: throw `ModelStoreError(.migrationRequired)` for
    ///   `migration` `.fail`, and empty the store for `.reset`.
    ///
    /// `name` is one path component of letters, digits, `-`, `_` and `.`.
    /// Throw a `ModelStoreError` to say why it failed; any other error is
    /// reported as `unknown`, with its description.
    func open(_ name: String, model: Model, indexes: [EntityName: [[PropertyKey]]], migration: ModelMigration) async throws -> any ModelStorage

    /// Deletes the store `name` and everything in it. Fine if there's none.
    func destroy(_ name: String) async throws
}

/// A backend that can apply a batch's changes together. Without it, the
/// changes are applied one after another, and one that fails leaves the
/// ones before it in place.
public protocol AtomicModelStorage: ModelStorage {

    /// Applies the changes in order: all of them, or, if it throws, none.
    func perform(_ changes: ModelChanges) async throws
}

/// The `ModelStore` contract over any CoreModel `ModelStorage`.
///
/// ```swift
/// HostModelStore.configure(.init(provider: MyStores(directory: container + "/Stores")))
/// HostModelStoreModule.register(in: runtime)
/// ```
///
/// The guest's schema, fetch, predicate and record objects build
/// CoreModel's `Model`, `FetchRequest` and `ModelData`. Each operation
/// calls the backend off the main thread, one at a time for a store's
/// name and in the order issued, and answers on the main thread. What a
/// fetch returned is kept as its `ModelResults`.
public final class HostModelStore: ModelStore {

    public struct Configuration: Sendable {

        public var provider: any ModelStorageProvider

        /// Runs an answer on the main thread. The default is the main
        /// dispatch queue; a host with a loop of its own posts to that.
        public var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

        public init(
            provider: any ModelStorageProvider,
            deliver: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
        ) {
            self.provider = provider
            self.deliver = deliver ?? Self.onMain
        }

        static let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    }

    // Everything static here is the main thread's.

    nonisolated(unsafe) private static var configuration: Configuration?

    /// The last operation issued for each store name: the next waits for it.
    nonisolated(unsafe) private static var tails: [String: Task<Void, Never>] = [:]

    /// The open stores, by name, for telling each of the others' changes.
    nonisolated(unsafe) private static var opened: [String: [WeakStore]] = [:]

    /// Says where stores are kept. Before it's called, `open` fails with
    /// `unavailable`.
    public static func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Forgets the provider: `open` fails again.
    static func unconfigure() {
        configuration = nil
    }

    /// Returns once every operation issued so far has been answered, and
    /// every operation those answers led the guest to issue. For tests
    /// that drive a guest and then look at what it shows.
    @MainActor
    public static func waitUntilIdle() async {
        while true {
            let pending = Set(tails.values)
            for task in pending {
                await task.value
            }
            // The last answers are on their way to the main thread; this
            // goes the same way, behind them.
            let deliver = configuration?.deliver ?? Configuration.onMain
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                deliver { continuation.resume() }
            }
            if Set(tails.values) == pending {
                return
            }
        }
    }

    let name: String

    /// The model the store was opened for; `nil` when it couldn't be.
    let model: Model?

    private let delegate: any ModelStoreDelegate

    private let session = Session()

    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

    private init(name: String, model: Model?, delegate: any ModelStoreDelegate, deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.name = name
        self.model = model
        self.delegate = delegate
        self.deliver = deliver
    }

    // MARK: ModelStore

    public static func open(_ name: String, schema: any ModelSchema, migration: Int32, delegate: any ModelStoreDelegate, callback: any ModelStoreCallback) -> HostModelStore {
        let configuration = configuration
        let deliver = configuration?.deliver ?? Configuration.onMain
        var model: Model?
        var declared: [EntityName: [[PropertyKey]]] = [:]
        var failure: ModelStoreError?
        if configuration == nil {
            failure = ModelStoreError(.unavailable, message: "this host keeps no stores")
        } else if !isValid(name: name) {
            failure = ModelStoreError(.invalidRequest, message: "a store's name is one path component of letters, digits, '-', '_' and '.'")
        } else if let schema = HostModelStoreModule.host(schema, as: HostModelSchema.self) {
            switch schema.model() {
            case .success(let made):
                model = made
                declared = schema.indexes
            case .failure(let error):
                failure = error
            }
        } else {
            failure = ModelStoreError(.invalidModel, message: "a schema that isn't this host's")
        }
        let usable: Model? = failure == nil ? model : nil
        let store = HostModelStore(name: name, model: usable, delegate: delegate, deliver: deliver)
        let session = store.session
        // Carried through the work to the main thread, and released there.
        let callback = MainThreadHeld(callback)
        guard let provider = configuration?.provider, let usable else {
            let refusal = failure ?? ModelStoreError(.unknown)
            session.failure = refusal
            enqueue(name) {
                deliver { callback.take()?.didFail(refusal.code.rawValue, message: refusal.message) }
            }
            return store
        }
        let indexes = declared
        opened[name] = (opened[name] ?? []).filter { $0.store != nil } + [WeakStore(store)]
        let migration = ModelMigration(rawValue: migration) ?? .fail
        enqueue(name) {
            do {
                session.backend = try await provider.open(name, model: usable, indexes: indexes, migration: migration)
                deliver { callback.take()?.didComplete() }
            } catch {
                let failure = Self.failure(error)
                session.failure = failure
                deliver { callback.take()?.didFail(failure.code.rawValue, message: failure.message) }
            }
        }
        return store
    }

    public func fetch(_ fetch: any ModelFetch, callback: any ModelStoreCallback) {
        guard let request = request(fetch, callback) else { return }
        run(callback) { backend in
            .results(try await Self.objects(backend, request))
        }
    }

    public func fetchIDs(_ fetch: any ModelFetch, callback: any ModelStoreCallback) {
        guard let request = request(fetch, callback) else { return }
        run(callback) { backend in
            if request.ids == nil {
                return .ids(try await backend.fetchID(request.request).map(\.rawValue))
            }
            return .ids(try await Self.objects(backend, request).map(\.id.rawValue))
        }
    }

    public func count(_ fetch: any ModelFetch, callback: any ModelStoreCallback) {
        guard let request = request(fetch, callback) else { return }
        run(callback) { backend in
            if request.ids == nil {
                return .count(Int64(clamping: try await backend.count(request.request)))
            }
            return .count(Int64(try await Self.objects(backend, request).count))
        }
    }

    public func perform(_ batch: any ModelBatch, callback: any ModelStoreCallback) {
        guard let model else {
            // The open failed; `run` answers with why.
            return run(callback) { _ in .complete }
        }
        guard let batch = HostModelStoreModule.host(batch, as: HostModelBatch.self) else {
            return reply(callback, ModelStoreError(.invalidRequest, message: "a batch that isn't this host's"))
        }
        let changes: ModelChanges
        switch batch.changes(in: model) {
        case .success(let read): changes = read
        case .failure(let error): return reply(callback, error)
        }
        run(callback, changed: Self.touched(by: changes, in: model)) { backend in
            if let atomic = backend as? any AtomicModelStorage {
                try await atomic.perform(changes)
            } else {
                for change in changes.changes {
                    switch change {
                    case .insert(let data): try await backend.insert(data)
                    case .delete(let entity, let id): try await backend.delete(entity, for: id)
                    }
                }
            }
            return .complete
        }
    }

    public static func destroy(_ name: String, callback: any ModelStoreCallback) {
        let callback = MainThreadHeld(callback)
        guard let configuration else {
            return Configuration.onMain { callback.take()?.didFail(ModelStoreError.Code.unavailable.rawValue, message: "this host keeps no stores") }
        }
        let deliver = configuration.deliver
        guard isValid(name: name) else {
            return enqueue(name) {
                deliver { callback.take()?.didFail(ModelStoreError.Code.invalidRequest.rawValue, message: "not a store's name") }
            }
        }
        let provider = configuration.provider
        enqueue(name) {
            do {
                try await provider.destroy(name)
                deliver { callback.take()?.didComplete() }
            } catch {
                let failure = Self.failure(error)
                deliver { callback.take()?.didFail(failure.code.rawValue, message: failure.message) }
            }
        }
    }

    // MARK: Running operations

    /// What an operation answers its callback with.
    private enum Answer: Sendable {
        case complete
        case results([ModelData])
        case ids([String])
        case count(Int64)
        case failure(ModelStoreError)
    }

    /// The backend, once the store is open; touched only by the store's
    /// operations, which run one at a time.
    private final class Session: @unchecked Sendable {
        var backend: (any ModelStorage)?
        var failure: ModelStoreError?
    }

    /// Runs `work` after everything issued for the store `name` before it.
    private static func enqueue(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = tails[name]
        tails[name] = Task {
            await previous?.value
            await work()
        }
    }

    /// Runs `operation` on the backend, in turn, and answers `callback` on
    /// the main thread; then tells every open store of this name which
    /// entities `changed`.
    private func run(_ callback: any ModelStoreCallback, changed: [String] = [], _ operation: @escaping @Sendable (any ModelStorage) async throws -> Answer) {
        let session = session
        let deliver = deliver
        let name = name
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld(callback)
        Self.enqueue(name) {
            let answer: Answer
            if let failure = session.failure {
                answer = .failure(failure)
            } else if let backend = session.backend {
                do {
                    answer = try await operation(backend)
                } catch {
                    answer = .failure(Self.failure(error))
                }
            } else {
                answer = .failure(ModelStoreError(.unavailable))
            }
            deliver {
                guard let callback = held.take() else { return }
                switch answer {
                case .complete: callback.didComplete()
                case .results(let objects): callback.didFetch(HostModelResults(objects))
                case .ids(let ids): callback.didFetchIDs(ids)
                case .count(let count): callback.didCount(count)
                case .failure(let error): callback.didFail(error.code.rawValue, message: error.message)
                }
                if case .complete = answer, !changed.isEmpty {
                    Self.notify(name, changed)
                }
            }
        }
    }

    /// Answers `callback` with a failure, in turn.
    private func reply(_ callback: any ModelStoreCallback, _ error: ModelStoreError) {
        let deliver = deliver
        let callback = MainThreadHeld(callback)
        Self.enqueue(name) {
            deliver { callback.take()?.didFail(error.code.rawValue, message: error.message) }
        }
    }

    /// The request behind a guest's fetch; `nil` once `callback` has been
    /// told what's wrong with it.
    private func request(_ fetch: any ModelFetch, _ callback: any ModelStoreCallback) -> HostModelFetch.Request? {
        guard let model else {
            run(callback) { _ in .complete }
            return nil
        }
        guard let fetch = HostModelStoreModule.host(fetch, as: HostModelFetch.self) else {
            reply(callback, ModelStoreError(.invalidRequest, message: "a fetch that isn't this host's"))
            return nil
        }
        switch fetch.request(in: model) {
        case .success(let request):
            return request
        case .failure(let error):
            reply(callback, error)
            return nil
        }
    }

    private static func notify(_ name: String, _ entities: [String]) {
        let stores = (opened[name] ?? []).compactMap(\.store)
        opened[name] = stores.map(WeakStore.init)
        for store in stores {
            store.delegate.didChange(store, entities: entities)
        }
    }

    // MARK: The backend

    private static func objects(_ backend: any ModelStorage, _ fetch: HostModelFetch.Request) async throws -> [ModelData] {
        let request = fetch.request
        guard let ids = fetch.ids else {
            return try await backend.fetch(request)
        }
        var found = [ModelData]()
        if request.predicate == nil {
            var seen = Set<ObjectID>()
            for id in ids where seen.insert(id).inserted {
                if let object = try await backend.fetch(request.entity, for: id) {
                    found.append(object)
                }
            }
            // Sorts, and cuts to the offset and limit.
            return request.evaluate(found)
        }
        // The backend applies the predicate, which may go through
        // relationships; the IDs, offset and limit are applied here.
        var whole = request
        whole.fetchLimit = 0
        whole.fetchOffset = 0
        let wanted = Set(ids)
        found = try await backend.fetch(whole).filter { wanted.contains($0.id) }
        if request.fetchOffset > 0 {
            found = Array(found.dropFirst(request.fetchOffset))
        }
        if request.fetchLimit > 0 {
            found = Array(found.prefix(request.fetchLimit))
        }
        return found
    }

    /// The entities a batch touches: those of its objects, and those their
    /// relationships point at, whose other side changes with them.
    private static func touched(by changes: ModelChanges, in model: Model) -> [String] {
        var touched = Set<String>()
        for change in changes.changes {
            let entity: EntityName
            switch change {
            case .insert(let data): entity = data.entity
            case .delete(let name, _): entity = name
            }
            guard touched.insert(entity.rawValue).inserted else { continue }
            for relationship in model[entity]?.relationships ?? [] {
                touched.insert(relationship.destinationEntity.rawValue)
            }
        }
        return touched.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func failure(_ error: any Error) -> ModelStoreError {
        if let error = error as? ModelStoreError {
            return error
        }
        if case .invalidEntity(let entity)? = error as? CoreModelError {
            return ModelStoreError(.invalidRequest, message: "no entity \(entity)")
        }
        return ModelStoreError(.unknown, message: String(describing: error))
    }

    /// One path component that's safe on every host's file system.
    static func isValid(name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, bytes[0] != UInt8(ascii: ".") else {
            return false
        }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }
}

/// The model store module: `ModelStore`, the objects it's described and
/// queried with, and its callbacks.
public enum HostModelStoreModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            ModelStoreProxy.descriptor, ModelSchemaProxy.descriptor, ModelEntityProxy.descriptor,
            ModelPropertyProxy.descriptor, ModelFetchProxy.descriptor, ModelPredicateProxy.descriptor,
            ModelExpressionProxy.descriptor, ModelRecordProxy.descriptor, ModelResultsProxy.descriptor,
            ModelBatchProxy.descriptor, ModelStoreCallbackProxy.descriptor, ModelStoreDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        ModelStoreProxy.register(HostModelStore.self, in: registrar)
        ModelSchemaProxy.register(HostModelSchema.self, in: registrar)
        ModelEntityProxy.register(HostModelEntity.self, in: registrar)
        ModelPropertyProxy.register(HostModelProperty.self, in: registrar)
        ModelFetchProxy.register(HostModelFetch.self, in: registrar)
        ModelPredicateProxy.register(HostModelPredicate.self, in: registrar)
        ModelExpressionProxy.register(HostModelExpression.self, in: registrar)
        ModelRecordProxy.register(HostModelRecord.self, in: registrar)
        ModelResultsProxy.register(HostModelResults.self, in: registrar)
        ModelBatchProxy.register(HostModelBatch.self, in: registrar)
        ModelStoreCallbackProxy.registerInterface(in: registrar)
        ModelStoreDelegateProxy.registerInterface(in: registrar)
        native = registrar as? NativeRuntime
    }

    /// The runtime the guest's proxies come from: the last `NativeRuntime`
    /// registered with, else `NativeRuntime.shared`.
    nonisolated(unsafe) static var native: NativeRuntime?

    /// The object of this module behind `value`. A schema, a fetch or a
    /// record the guest passes back arrives as a proxy even though this
    /// module made it, and its contract has no way to read it back; so the
    /// implementation recovers its own object. `nil` for one implemented
    /// elsewhere.
    static func host<T: AnyObject>(_ value: AnyObject, as type: T.Type) -> T? {
        if let object = value as? T {
            return object
        }
        guard let proxy = value as? DynamicObject else {
            return nil
        }
        return (native ?? .shared).swiftObject(for: proxy) as? T
    }
}

private struct WeakStore {

    weak var store: HostModelStore?

    init(_ store: HostModelStore) {
        self.store = store
    }
}
