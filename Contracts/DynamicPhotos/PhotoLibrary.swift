import DynamicFiles
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The photos and videos the system keeps for the user: PhotoKit's place.
///
/// ```swift
/// let library = PhotoLibrary.shared
/// try await library.add(photo: .caches / "shot.jpg")
///
/// guard await library.requestAccess().allowsReading else { return }
/// let recent = try await library.assets()             // newest first
/// let first = try await recent.assets(in: 0..<60)
/// ```
///
/// An app whose manifest declares `.photoLibrary(.addOnly)` adds and
/// reads nothing. One that declares `.readWrite` browses the library, or
/// the photos the user chose to give it, and deletes with the user's
/// leave. To be given one photo, an app needs none of this: it asks
/// `DocumentPicker` for one from the photo library.
///
/// Every call is asynchronous, with a completion-handler form. It's
/// guest-side only, over the `Photos` contract, which requires
/// `.photoLibrary` in the manifest. The guest is single-threaded (§6.4).
public final class PhotoLibrary: @unchecked Sendable {

    /// The system's library.
    public static let shared = PhotoLibrary()

    /// The host's library, made when first used.
    private var made: (any Photos)?

    private let listener = Listener()

    init() { }

    private var library: any Photos {
        if let made {
            return made
        }
        let library = PhotosProxy.shared()
        made = library
        return library
    }

    // MARK: Access

    /// What the app may do with the library now. Never asks.
    public var access: PhotoLibraryAccess {
        // An access from a newer host isn't one to rely on.
        PhotoLibraryAccess(rawValue: library.access()) ?? .denied
    }

    /// Asks the user if they haven't decided, for what the manifest
    /// declares, and gives what the app has afterwards.
    public func requestAccess(completion: @escaping (PhotoLibraryAccess) -> Void) {
        library.requestAccess(Receiver { outcome in
            if case .access(let access) = outcome {
                completion(access)
            } else {
                completion(.denied)
            }
        })
    }

    // MARK: Adding

    /// Copies a JPEG, PNG or HEIC file into the library; the app keeps its
    /// own. It gives the new asset to an app that may read the library,
    /// and `nil` to one that may only add.
    public func add(photo file: FilePath, completion: @escaping (Result<PhotoAsset?, PhotoLibraryError>) -> Void) {
        add(file, .image, completion)
    }

    /// Copies an MP4 or MOV file into the library.
    public func add(video file: FilePath, completion: @escaping (Result<PhotoAsset?, PhotoLibraryError>) -> Void) {
        add(file, .video, completion)
    }

    private func add(_ file: FilePath, _ kind: PhotoKind, _ completion: @escaping (Result<PhotoAsset?, PhotoLibraryError>) -> Void) {
        library.add(file.directory.rawValue, path: file.path, kind: kind.rawValue, callback: Receiver { outcome in
            if case .added(let asset) = outcome {
                completion(.success(asset))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Browsing

    /// The library's photos and videos, newest first: all of them, those
    /// of one kind, or those in an album. The result is the library as it
    /// is now; after a change, fetch again.
    public func assets(
        of kind: PhotoKind? = nil,
        in album: PhotoAlbum? = nil,
        completion: @escaping (Result<PhotoFetchResult, PhotoLibraryError>) -> Void
    ) {
        library.fetch(kind?.rawValue ?? 0, album: album?.id ?? "", callback: Receiver { outcome in
            if case .fetched(let results) = outcome {
                completion(.success(results))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// One asset by its identifier; `nil` when it's gone.
    public func asset(withID identifier: String, completion: @escaping (Result<PhotoAsset?, PhotoLibraryError>) -> Void) {
        library.asset(identifier, callback: Receiver { outcome in
            if case .asset(let asset) = outcome {
                completion(.success(asset))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// The albums the user made, and those the system keeps.
    public func albums(completion: @escaping (Result<[PhotoAlbum], PhotoLibraryError>) -> Void) {
        library.albums(Receiver { outcome in
            if case .albums(let albums) = outcome {
                completion(.success(albums))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Originals

    /// The asset's original, as a file: for playing a video, decoding, or
    /// sending. It may take as long as a download, where the library is
    /// kept in the cloud; offline, that fails with `unavailable`.
    public func file(for asset: PhotoAsset, completion: @escaping (Result<PhotoFile, PhotoLibraryError>) -> Void) {
        library.file(asset.id, callback: Receiver { outcome in
            if case .file(let file) = outcome {
                completion(.success(file))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Deleting

    /// Deletes all of them or none. The system asks the user first;
    /// refusing fails with `cancelledByUser`.
    public func delete(_ assets: [PhotoAsset], completion: @escaping (Result<Void, PhotoLibraryError>) -> Void) {
        library.delete(assets.map { $0.id }, callback: Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Changes

    /// Called when anything in the library changed: a photo taken, a
    /// sync, another app, or this app. It doesn't say what; fetch again.
    /// One listener at a time: a new closure, or a `changes` stream,
    /// replaces it, and `nil` stops it.
    public func onChange(_ handler: (() -> Void)?) {
        listener.handler = handler
        library.setDelegate(handler == nil ? nil : listener)
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func requestAccess() async -> PhotoLibraryAccess {
        await withCallback { (callback: Callback<PhotoLibraryAccess, Never>) in
            self.requestAccess { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: .denied)
        }
    }

    @discardableResult
    public nonisolated(nonsending) func add(photo file: FilePath) async throws(PhotoLibraryError) -> PhotoAsset? {
        try await photoResult { self.add(photo: file, completion: $0) }
    }

    @discardableResult
    public nonisolated(nonsending) func add(video file: FilePath) async throws(PhotoLibraryError) -> PhotoAsset? {
        try await photoResult { self.add(video: file, completion: $0) }
    }

    public nonisolated(nonsending) func assets(of kind: PhotoKind? = nil, in album: PhotoAlbum? = nil) async throws(PhotoLibraryError) -> PhotoFetchResult {
        try await photoResult { self.assets(of: kind, in: album, completion: $0) }
    }

    public nonisolated(nonsending) func asset(withID identifier: String) async throws(PhotoLibraryError) -> PhotoAsset? {
        try await photoResult { self.asset(withID: identifier, completion: $0) }
    }

    public nonisolated(nonsending) func albums() async throws(PhotoLibraryError) -> [PhotoAlbum] {
        try await photoResult { self.albums(completion: $0) }
    }

    public nonisolated(nonsending) func file(for asset: PhotoAsset) async throws(PhotoLibraryError) -> PhotoFile {
        try await photoResult { self.file(for: asset, completion: $0) }
    }

    public nonisolated(nonsending) func delete(_ assets: [PhotoAsset]) async throws(PhotoLibraryError) {
        try await photoResult { self.delete(assets, completion: $0) }
    }

    /// One element each time the library changes. Ending the loop stops
    /// listening. It replaces an `onChange` closure, and another stream.
    public var changes: EventStream<Void, Never> {
        let (stream, continuation) = EventStream<Void, Never>.makeStream()
        listener.generation &+= 1
        let generation = listener.generation
        onChange {
            continuation.yield(())
        }
        continuation.onTermination = { [listener, library] in
            // Unless something else listens by now.
            guard listener.generation == generation else { return }
            listener.handler = nil
            library.setDelegate(nil)
        }
        return stream
    }
    #endif
}

/// A fetch's results: a list too long to hold, read as it's needed. It's
/// the library as it was when the fetch was made.
///
/// ```swift
/// let recent = try await library.assets()
/// recent.count                                        // 31 204
/// let row = try await recent.assets(in: 120..<180)
/// ```
public final class PhotoFetchResult: @unchecked Sendable {

    /// The host's results. Releasing them lets the host forget the fetch.
    private let results: any PhotoResults

    /// How many assets the fetch found.
    public let count: Int

    init(_ results: any PhotoResults) {
        self.results = results
        self.count = Int(max(results.count(), 0))
    }

    public var isEmpty: Bool {
        count == 0
    }

    /// The assets in a range of the results, newest first. What's past the
    /// end isn't given, and nor is an asset that has gone since.
    public func assets(in range: Range<Int>, completion: @escaping (Result<[PhotoAsset], PhotoLibraryError>) -> Void) {
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        guard lower < upper else {
            completion(.success([]))
            return
        }
        results.assets(Int32(clamping: lower), count: Int32(clamping: upper - lower), callback: Receiver { outcome in
            if case .assets(let assets) = outcome {
                completion(.success(assets))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func assets(in range: Range<Int>) async throws(PhotoLibraryError) -> [PhotoAsset] {
        try await photoResult { self.assets(in: range, completion: $0) }
    }
    #endif
}

/// An asset's original, as a file: read-only, in whatever format the
/// camera made.
///
/// ```swift
/// let file = try await library.file(for: asset)
/// player.load(.file(file.path))
/// ```
///
/// `path` is good while the app holds this object. Releasing it ends the
/// access, and a `FilePath` kept past that fails with
/// `FileError.notPermitted`.
public final class PhotoFile: @unchecked Sendable {

    /// The host's grant. Its release is what ends the access.
    private let grant: any PhotoFileGrant

    /// Where `FileManager`, and any contract that takes a `FilePath`,
    /// finds it.
    public let path: FilePath

    /// A MIME type: `image/heic`, `video/quicktime`.
    public let contentType: String

    /// The file's own name, where it has one.
    public let name: String?

    init(_ grant: any PhotoFileGrant) {
        self.grant = grant
        self.path = FilePath(FileDirectory(rawValue: grant.directory()))
        self.contentType = grant.contentType()
        let name = grant.name()
        self.name = name.isEmpty ? nil : name
    }
}

#if !EMBEDDED_NO_CONCURRENCY
/// Waits for a completion handler. A cancelled task stops waiting with
/// `cancelled`; the operation itself isn't undone.
nonisolated(nonsending) func photoResult<Value>(_ start: (@escaping (Result<Value, PhotoLibraryError>) -> Void) -> Void) async throws(PhotoLibraryError) -> Value {
    try await withCallback { (callback: Callback<Value, PhotoLibraryError>) in
        start { callback.resume(with: $0) }
    } onCancel: { callback in
        callback.resume(throwing: .cancelled)
    }
}
#endif

/// The delegate the host holds.
private final class Listener: PhotosDelegate {

    var handler: (() -> Void)?

    /// Counts listeners, so a stream that ends knows whether it's still
    /// the one listening.
    var generation = 0

    func didChange() {
        handler?()
    }
}

/// What a `PhotoCallback` was told.
private enum Outcome {

    case complete
    case access(PhotoLibraryAccess)
    case added(PhotoAsset?)
    case fetched(PhotoFetchResult)
    case assets([PhotoAsset])
    case asset(PhotoAsset?)
    case albums([PhotoAlbum])
    case file(PhotoFile)
    case failure(PhotoLibraryError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: PhotoLibraryError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: PhotoCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
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

    func didChangeAccess(_ access: Int32) {
        answer(.access(PhotoLibraryAccess(rawValue: access) ?? .denied))
    }

    func didAdd(_ fields: [String]) {
        answer(.added(PhotoAsset.assets(fields).first))
    }

    func didFetch(_ results: any PhotoResults) {
        answer(.fetched(PhotoFetchResult(results)))
    }

    func didListAssets(_ fields: [String]) {
        answer(.assets(PhotoAsset.assets(fields)))
    }

    func didFindAsset(_ fields: [String]) {
        answer(.asset(PhotoAsset.assets(fields).first))
    }

    func didListAlbums(_ fields: [String]) {
        answer(.albums(PhotoAlbum.albums(fields)))
    }

    func didOpenFile(_ file: any PhotoFileGrant) {
        answer(.file(PhotoFile(file)))
    }

    func didFail(_ error: Int32) {
        answer(.failure(PhotoLibraryError(rawValue: error) ?? .unknown))
    }
}
