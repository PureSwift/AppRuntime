import CoreModel
import DynamicRuntime
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif

/// A fetch whose results stay current: the place of
/// `NSFetchedResultsController` and SwiftData's `@Query`.
///
/// ```swift
/// let people = Query<Person>(store, sort: [.init(property: "name")])
///
/// // In a view's body:
/// List(people.results) { person in
///     Text(person.name)
/// }
/// ```
///
/// It fetches when it's made, and again when the store reports a change to
/// its entity, or to one its predicate reaches through a relationship.
/// Each fetch swaps in a new snapshot; several changes in one turn of the
/// guest are one fetch. It's observable, so the views that read `results`,
/// `isLoading` or `error` update.
public final class Query<Element: Entity>: Observable {

    public let storage: RuntimeModelStorage

    private let registrar = ObservationRegistrar()

    private var request: FetchRequest

    private var current = FetchedResults<Element>()

    private var loading = false

    private var failure: ModelStoreError?

    /// The entities whose changes mean fetching again.
    private var watched: Set<EntityName> = []

    private var observer = 0

    /// Which fetch is the latest; an older one's answer is dropped.
    private var generation = 0

    private var isScheduled = false

    public init(
        _ storage: RuntimeModelStorage,
        predicate: FetchRequest.Predicate? = nil,
        sort: [FetchRequest.SortDescriptor] = [],
        limit: Int = 0
    ) {
        self.storage = storage
        self.request = FetchRequest(entity: Element.entityName, sortDescriptors: sort, predicate: predicate, fetchLimit: limit)
        watch()
        // The storage holds the observer, so it refers to this query
        // without owning it, until `deinit` removes it.
        let query = Unmanaged.passUnretained(self)
        observer = storage.addChangeObserver { entities in
            query.takeUnretainedValue().storeDidChange(entities)
        }
        refetch()
    }

    deinit {
        storage.removeChangeObserver(observer)
    }

    // MARK: Reading

    /// What the latest fetch found. Empty until the first one answers; a
    /// failed fetch leaves it as it was.
    public var results: FetchedResults<Element> {
        registrar.access(self, propertyIndex: 0)
        return current
    }

    /// Whether a fetch is under way.
    public var isLoading: Bool {
        registrar.access(self, propertyIndex: 1)
        return loading
    }

    /// Why the latest fetch failed; `nil` when it didn't.
    public var error: ModelStoreError? {
        registrar.access(self, propertyIndex: 2)
        return failure
    }

    // MARK: The request

    public var predicate: FetchRequest.Predicate? {
        get { request.predicate }
        set {
            request.predicate = newValue
            watch()
            setNeedsFetch()
        }
    }

    public var sort: [FetchRequest.SortDescriptor] {
        get { request.sortDescriptors }
        set {
            request.sortDescriptors = newValue
            setNeedsFetch()
        }
    }

    /// 0: no limit.
    public var limit: Int {
        get { request.fetchLimit }
        set {
            request.fetchLimit = newValue
            setNeedsFetch()
        }
    }

    /// Fetches again now.
    public func refetch() {
        generation += 1
        let generation = generation
        if !loading {
            registrar.withMutation(of: self, propertyIndex: 1) { loading = true }
        }
        // The host holds the callback, and so this query, until it answers.
        storage.records(for: request) { result in
            guard generation == self.generation else { return }
            switch result {
            case .success(let records):
                self.registrar.withMutation(of: self, propertyIndex: 0) { self.current = FetchedResults(records) }
                if self.failure != nil {
                    self.registrar.withMutation(of: self, propertyIndex: 2) { self.failure = nil }
                }
            case .failure(let error):
                self.registrar.withMutation(of: self, propertyIndex: 2) { self.failure = error }
            }
            self.registrar.withMutation(of: self, propertyIndex: 1) { self.loading = false }
        }
    }

    /// Fetches once this turn of the guest is over, however often it's
    /// asked before then.
    private func setNeedsFetch() {
        guard !isScheduled else { return }
        isScheduled = true
        GuestExecutor.whenIdle {
            self.isScheduled = false
            self.refetch()
        }
    }

    private func storeDidChange(_ entities: [EntityName]) {
        if entities.contains(where: { watched.contains($0) }) {
            setNeedsFetch()
        }
    }

    /// Works out which entities the request reads: its own, and those its
    /// predicate's key paths go through.
    private func watch() {
        var watched: Set<EntityName> = [request.entity]
        for keyPath in request.predicate?.keyPaths ?? [] {
            var entity = storage.model[request.entity]
            for key in keyPath.keys {
                guard case .property(let name) = key, !name.isEmpty,
                      let relationship = entity?[relationship: PropertyKey(rawValue: name)] else {
                    break
                }
                watched.insert(relationship.destinationEntity)
                entity = storage.model[relationship.destinationEntity]
            }
        }
        self.watched = watched
    }
}
