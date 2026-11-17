import DynamicRuntime

/// An open model store: entities, attributes and relationships, kept by the
/// host in what its platform has (§7.9). App code uses CoreModel, through
/// `RuntimeModelStorage`, which wraps these contracts.
///
/// Every operation completes through its `callback`, which the host holds
/// until it has called exactly one of its methods, on the main thread: a
/// browser's storage can't be used synchronously there, and no host should
/// read a disk there. A store's operations take effect in the order they
/// were issued, and their callbacks arrive in that order.
///
/// It needs no capability: the store is in the app's own container.
///
/// | Host | Kept in |
/// |---|---|
/// | iOS / macOS | Core Data, through CoreModel's `CoreDataModel` |
/// | Android | SQLite |
/// | Linux | SQLite, through CoreModel-SQLite |
/// | Browser | IndexedDB |
@DynamicRuntime("org.pureswift.data.ModelStore")
public protocol ModelStore: AnyObject {

    /// Opens the store `name` for `schema`. `migration` is a
    /// `ModelMigration` raw value. Operations may be issued at once; they
    /// wait for the open, whose outcome is `callback`'s `didComplete` or
    /// `didFail`.
    static func open(_ name: String, schema: ModelSchema, migration: Int32,
                     delegate: ModelStoreDelegate, callback: ModelStoreCallback) -> Self

    /// Answers `didFetch`.
    func fetch(_ fetch: ModelFetch, callback: ModelStoreCallback)

    /// Answers `didFetchIDs`.
    func fetchIDs(_ fetch: ModelFetch, callback: ModelStoreCallback)

    /// Answers `didCount`.
    func count(_ fetch: ModelFetch, callback: ModelStoreCallback)

    /// Applies a batch's inserts and deletes together. Answers
    /// `didComplete`; a failed batch changes nothing.
    func perform(_ batch: ModelBatch, callback: ModelStoreCallback)

    /// Deletes the store `name` and everything in it. Answers
    /// `didComplete`.
    static func destroy(_ name: String, callback: ModelStoreCallback)
}

/// The outcome of one `ModelStore` operation. The host calls exactly one of
/// these, once, on the main thread.
@DynamicCallback("org.pureswift.data.ModelStoreCallback")
public protocol ModelStoreCallback: AnyObject {

    func didComplete()

    func didFetch(_ results: ModelResults)

    func didFetchIDs(_ ids: [String])

    func didCount(_ count: Int64)

    /// `error` is a `ModelStoreError.Code` raw value; `message` is the
    /// backend's own description, for logs.
    func didFail(_ error: Int32, message: String)
}

/// What a `ModelStore` tells its app without being asked.
@DynamicCallback("org.pureswift.data.ModelStoreDelegate")
public protocol ModelStoreDelegate: AnyObject {

    /// A batch was committed that touched these entities: by this store
    /// object, or by another on the same store (another tab, an extension).
    /// It comes after the batch's own callback, once per batch.
    func didChange(_ store: ModelStore, entities: [String])
}
