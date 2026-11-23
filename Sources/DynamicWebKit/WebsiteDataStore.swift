import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
import _Concurrency
#endif

/// Where pages keep cookies, storage and caches.
///
/// `.default` is the app's, kept between runs. A `.nonPersistent()` store
/// is kept only while a page uses it, and forgets everything when the last
/// one goes: a private tab. Pages made with the same store share it.
///
/// ```swift
/// let store = WebsiteDataStore.nonPersistent()
/// let tab = WebPage(configuration: .init(websiteDataStore: store))
/// ```
public struct WebsiteDataStore: Equatable, Hashable, Sendable {

    /// 0 for the default store; a number of its own for each other.
    let identifier: Int32

    /// The app's own, kept between runs.
    public static let `default` = WebsiteDataStore(identifier: 0)

    /// A store of its own that keeps nothing once no page uses it. Pages
    /// with it are made only where `WebPage.hostFeatures` includes
    /// `.nonPersistentStores`.
    public static func nonPersistent() -> WebsiteDataStore {
        next = next == .max ? 1 : next + 1
        return WebsiteDataStore(identifier: next)
    }

    nonisolated(unsafe) private static var next: Int32 = 0

    public var isPersistent: Bool {
        identifier == 0
    }

    /// Removes cookies, storage, caches and the rest of what sites kept in
    /// this store since `since`, seconds since 1970, for every page that
    /// uses it: 0, the default, removes everything. Needs
    /// `.removingData`; fails with `unavailable` without it.
    public func removeData(since: Double = 0, completion: @escaping (Result<Void, WebError>) -> Void) {
        guard WebPage.hostFeatures.contains(.removingData) else {
            completion(.failure(WebError(.unavailable)))
            return
        }
        // A page of the store, unseen, asks the host; it's kept until the
        // host answers.
        let page = WebPage(made: WebPage.Configuration(websiteDataStore: self))
        page.removeData(since: since) { result in
            withExtendedLifetime(page) {
                completion(result)
            }
        }
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Removes what sites kept in this store since `since`, seconds since
    /// 1970; 0 removes everything.
    ///
    /// - Throws: `WebError` with `.unavailable` where the host can't.
    public func removeData(since: Double = 0) async throws(WebError) {
        try await withCallback { (callback: Callback<Void, WebError>) in
            self.removeData(since: since) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: WebError(.cancelled))
        }
    }
    #endif
}
