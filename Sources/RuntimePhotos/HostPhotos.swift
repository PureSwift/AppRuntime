import Dispatch
import DynamicFiles
import DynamicPhotos
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// One asset's original, where the host's process can read it.
public struct HostPhotoOriginal: Equatable, Sendable {

    /// An absolute path, good until `PhotoStore.release` is called with
    /// this original.
    public var path: String

    /// A MIME type: `image/heic`, `video/quicktime`.
    public var contentType: String

    /// The file's own name, where the library keeps one.
    public var name: String?

    public init(path: String, contentType: String, name: String? = nil) {
        self.path = path
        self.contentType = contentType
        self.name = name
    }
}

/// The platform's photo library: `PHPhotoLibrary`, `MediaStore`. It works
/// in the guest's own values. It's called off the main thread, by one
/// thread at a time, in the order the guest asked.
///
/// `HostPhotos` has checked access before a store sees a call. With
/// limited access the store is the photos the user chose, and what the
/// app added: it says nothing of the others.
public protocol PhotoStore: AnyObject, Sendable {

    /// Copies the file at an absolute path into the library, and gives
    /// the new asset. A file the library doesn't take is `invalidData`.
    func add(fileAt path: String, kind: PhotoKind) throws(PhotoLibraryError) -> PhotoAsset

    /// The identifiers of the assets of `kind`, or of both kinds, in an
    /// album or in the whole library: newest first, by creation date. An
    /// album that's gone is `notFound`.
    func identifiers(of kind: PhotoKind?, in album: String?) throws(PhotoLibraryError) -> [String]

    /// The assets with these identifiers that are still there, in any
    /// order. Sizes are the upright picture's.
    func assets(withIDs identifiers: [String]) throws(PhotoLibraryError) -> [PhotoAsset]

    /// The albums the user made, and those the system keeps.
    func albums() throws(PhotoLibraryError) -> [PhotoAlbum]

    /// The original, unchanged, fetched from the cloud if it must be:
    /// `unavailable` when it can't be now, `notFound` when it's gone.
    func original(of identifier: String) throws(PhotoLibraryError) -> HostPhotoOriginal

    /// The guest let go of an original: remove the copy made for it.
    func release(_ original: HostPhotoOriginal)
}

/// The `Photos` contract over a host's `PhotoStore`: what every host
/// written in Swift shares.
///
/// It checks access before every call, keeps an app that declared adding
/// alone from reading, finds the file to add and tells a photo from a
/// video by its first bytes, holds each fetch's identifiers and reads its
/// assets a page at a time, makes an original a grant in `HostFiles`, and
/// gathers a burst of changes into one report.
///
/// ```swift
/// HostPhotos.store = MyPhotoLibrary()
/// HostPhotos.allowsReading = true                    // RTCapabilityOptions.photoLibrary.access
/// HostPhotos.access = .notDetermined                 // what the platform says now
/// HostPhotos.requester = { completion in … }          // the platform's question
/// HostPhotos.deleter = { identifiers, completion in … }   // asks the user, then deletes
/// HostPhotosModule.register(in: runtime)
///
/// HostPhotos.libraryChanged()                        // from the platform
/// ```
///
/// Without a store every call fails with `unavailable`. The host's
/// renderer draws a `Photo` node from the platform's thumbnails itself:
/// this has no part in that. Main thread only.
public final class HostPhotos: Photos {

    // MARK: The host's settings

    /// The platform's library.
    nonisolated(unsafe) public static var store: (any PhotoStore)?

    /// What the user has granted, as the platform says. A platform that
    /// needs no leave to add says `.addOnly` from the start.
    nonisolated(unsafe) public static var access = PhotoLibraryAccess.notDetermined

    /// Whether the manifest declares browsing: `readWrite`, and not
    /// `addOnly`. An app that declared adding alone never reads, whatever
    /// the user granted.
    nonisolated(unsafe) public static var allowsReading = true

    /// Asks the user, for what the manifest declares, and says what they
    /// granted. Called on the main thread while the user hasn't decided.
    nonisolated(unsafe) public static var requester: ((@escaping (PhotoLibraryAccess) -> Void) -> Void)?

    /// Deletes assets, all of them or none, after the system's own
    /// question where the system has one: refusing is `cancelledByUser`.
    /// Called on the main thread, and answers on it. Without one, a
    /// deletion fails with `unavailable`.
    nonisolated(unsafe) public static var deleter: (([String], @escaping (Result<Void, PhotoLibraryError>) -> Void) -> Void)?

    /// Runs the store's work off the main thread. The default is a serial
    /// queue; whatever replaces it must keep the order.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.photos")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one library. Never replaced: a guest keeps the object it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostPhotos()

    public static func shared() -> HostPhotos {
        instance
    }

    /// Forgets the store, the settings and the guest's delegate, for
    /// tests and for a host that starts the guest again.
    public static func reset() {
        store = nil
        access = .notDetermined
        allowsReading = true
        requester = nil
        deleter = nil
        work = defaultWork
        deliver = defaultDeliver
        instance.delegate = nil
        instance.changePending = false
    }

    /// What the app has now: what the user granted, no more than the
    /// manifest declares, and nothing without a store.
    public static var effectiveAccess: PhotoLibraryAccess {
        guard store != nil else { return .unavailable }
        if !allowsReading, access.allowsReading {
            return .addOnly
        }
        return access
    }

    /// Whether the user has still to be asked for what the manifest
    /// declares.
    private static var isUndecided: Bool {
        access == .notDetermined || (access == .addOnly && allowsReading)
    }

    /// Something in the platform's library changed: a photo taken, a
    /// sync, another app. A burst of these reaches the guest as one
    /// `didChange`.
    public static func libraryChanged() {
        let instance = Self.instance
        guard !instance.changePending else { return }
        instance.changePending = true
        deliver {
            let instance = HostPhotos.shared()
            guard instance.changePending else { return }
            instance.changePending = false
            instance.delegate?.didChange()
        }
    }

    // MARK: State

    private var delegate: (any PhotosDelegate)?

    private var changePending = false

    // MARK: Answers

    /// Calls `answer` with the callback, on the main thread and later.
    fileprivate static func later(_ callback: any PhotoCallback, _ answer: @escaping (any PhotoCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    fileprivate static func fail(_ callback: any PhotoCallback, _ error: PhotoLibraryError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// The store, when the app may read it, or add to it if `adding`;
    /// otherwise the callback is failed.
    fileprivate static func store(for callback: any PhotoCallback, adding: Bool = false) -> (any PhotoStore)? {
        guard let store else {
            fail(callback, .unavailable)
            return nil
        }
        let access = effectiveAccess
        guard adding ? access.allowsAdding : access.allowsReading else {
            fail(callback, .notAuthorized)
            return nil
        }
        return store
    }

    /// Runs `operation` off the main thread, and answers `callback` on it
    /// with what `answer` makes of the result.
    fileprivate static func run<Value: Sendable>(
        _ callback: any PhotoCallback,
        _ operation: @escaping @Sendable () throws(PhotoLibraryError) -> Value,
        _ answer: @escaping (any PhotoCallback, Value) -> Void
    ) {
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld((callback, answer))
        let deliver = Self.deliver
        work {
            let result: Result<Value, PhotoLibraryError>
            do throws(PhotoLibraryError) {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }
            deliver {
                guard let (callback, answer) = held.take() else { return }
                switch result {
                case .success(let value):
                    answer(callback, value)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    // MARK: Access

    public func access() -> Int32 {
        Self.effectiveAccess.rawValue
    }

    /// Asks the user if they haven't decided, and says what the app has.
    public static func requestAccess(_ completion: @escaping (PhotoLibraryAccess) -> Void) {
        guard store != nil, isUndecided, let requester else {
            completion(effectiveAccess)
            return
        }
        var answered = false
        requester { granted in
            // A platform that answers twice is heard once.
            guard !answered else { return }
            answered = true
            access = granted
            completion(effectiveAccess)
        }
    }

    public func requestAccess(_ callback: any PhotoCallback) {
        Self.requestAccess { access in
            Self.later(callback) { $0.didChangeAccess(access.rawValue) }
        }
    }

    public func setDelegate(_ delegate: (any PhotosDelegate)?) {
        self.delegate = delegate
    }

    // MARK: Adding

    public func add(_ directory: Int32, path: String, kind: Int32, callback: any PhotoCallback) {
        guard let store = Self.store(for: callback, adding: true) else { return }
        guard let kind = PhotoKind(rawValue: kind) else {
            Self.fail(callback, .invalidData)
            return
        }
        let source: String
        do throws(FileError) {
            source = try HostFiles.path(of: directory, path: path)
        } catch {
            Self.fail(callback, error == .notPermitted ? .notAuthorized : .notFound)
            return
        }
        guard HostFiles.kind(ofItemAt: source) == .file else {
            Self.fail(callback, .notFound)
            return
        }
        // Only an app that may read hears which asset it made.
        let reads = Self.effectiveAccess.allowsReading
        Self.run(callback, { () throws(PhotoLibraryError) in
            guard PhotoFileFormat.detect(fileAt: source)?.kind == kind else {
                throw .invalidData
            }
            return try store.add(fileAt: source, kind: kind)
        }) { callback, asset in
            callback.didAdd(reads ? asset.fields : [])
            Self.libraryChanged()
        }
    }

    // MARK: Browsing

    public func fetch(_ kind: Int32, album: String, callback: any PhotoCallback) {
        guard let store = Self.store(for: callback) else { return }
        // A kind from a newer guest is one this host has none of.
        guard kind == 0 || PhotoKind(rawValue: kind) != nil else {
            Self.later(callback) { $0.didFetch(HostPhotoResults([])) }
            return
        }
        let kind = PhotoKind(rawValue: kind)
        let album = album.isEmpty ? nil : album
        Self.run(callback, { () throws(PhotoLibraryError) in try store.identifiers(of: kind, in: album) }) { callback, identifiers in
            callback.didFetch(HostPhotoResults(identifiers))
        }
    }

    public func asset(_ identifier: String, callback: any PhotoCallback) {
        guard let store = Self.store(for: callback) else { return }
        Self.run(callback, { () throws(PhotoLibraryError) in try store.assets(withIDs: [identifier]) }) { callback, assets in
            callback.didFindAsset(assets.first { $0.id == identifier }?.fields ?? [])
        }
    }

    public func albums(_ callback: any PhotoCallback) {
        guard let store = Self.store(for: callback) else { return }
        Self.run(callback, { () throws(PhotoLibraryError) in try store.albums() }) { callback, albums in
            callback.didListAlbums(PhotoAlbum.fields(albums))
        }
    }

    // MARK: Originals

    public func file(_ identifier: String, callback: any PhotoCallback) {
        guard let store = Self.store(for: callback) else { return }
        Self.run(callback, { () throws(PhotoLibraryError) in try store.original(of: identifier) }) { callback, original in
            callback.didOpenFile(HostPhotoFile(original, store: store))
        }
    }

    // MARK: Deleting

    public func delete(_ identifiers: [String], callback: any PhotoCallback) {
        guard Self.store(for: callback) != nil else { return }
        guard !identifiers.isEmpty else {
            Self.later(callback) { $0.didComplete() }
            return
        }
        guard let deleter = Self.deleter else {
            Self.fail(callback, .unavailable)
            return
        }
        var answered = false
        deleter(identifiers) { result in
            // A platform that answers twice is heard once.
            guard !answered else { return }
            answered = true
            Self.later(callback) { callback in
                switch result {
                case .success:
                    callback.didComplete()
                    Self.libraryChanged()
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }
}

/// One fetch: the identifiers there were, newest first, and their assets
/// a page at a time.
public final class HostPhotoResults: PhotoResults {

    public let identifiers: [String]

    init(_ identifiers: [String]) {
        self.identifiers = identifiers
    }

    public func count() -> Int32 {
        Int32(clamping: identifiers.count)
    }

    public func assets(_ start: Int32, count: Int32, callback: any PhotoCallback) {
        // Access may have gone since the fetch.
        guard let store = HostPhotos.store(for: callback) else { return }
        let lower = min(max(Int(start), 0), identifiers.count)
        let upper = min(lower + max(Int(count), 0), identifiers.count)
        let page = Array(identifiers[lower ..< upper])
        guard !page.isEmpty else {
            HostPhotos.later(callback) { $0.didListAssets([]) }
            return
        }
        HostPhotos.run(callback, { () throws(PhotoLibraryError) in
            // In the fetch's order, whatever order the store gave; one
            // that has gone since is left out.
            let found = try store.assets(withIDs: page)
            var byID: [String: PhotoAsset] = [:]
            for asset in found {
                byID[asset.id] = asset
            }
            return page.compactMap { byID[$0] }
        }) { callback, assets in
            callback.didListAssets(PhotoAsset.fields(assets))
        }
    }
}

/// One original the guest holds: a grant in `HostFiles` for as long as
/// this object lives, and the store's copy for as long.
public final class HostPhotoFile: PhotoFileGrant {

    public let original: HostPhotoOriginal

    private let store: any PhotoStore

    private let granted: FileDirectory

    init(_ original: HostPhotoOriginal, store: any PhotoStore) {
        self.original = original
        self.store = store
        self.granted = HostFiles.grant(HostFiles.Grant(path: original.path, kind: .file, isWritable: false))
    }

    deinit {
        HostFiles.revoke(granted)
        let (store, original) = (store, original)
        HostPhotos.work {
            store.release(original)
        }
    }

    public func directory() -> Int32 {
        granted.rawValue
    }

    public func name() -> String {
        original.name ?? ""
    }

    public func contentType() -> String {
        original.contentType
    }
}

/// Photo library access as the built-in `Permissions` contract reports it.
public final class PhotosPermission: PermissionProvider {

    public init() { }

    static func status(_ access: PhotoLibraryAccess, allowsReading: Bool) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .limited: return .limited
        case .unavailable: return .unavailable
        // All an app that only adds asked for; for one that browses, the
        // question hasn't been put.
        case .addOnly: return allowsReading ? .notDetermined : .granted
        }
    }

    public func status() -> PermissionStatus {
        Self.status(HostPhotos.effectiveAccess, allowsReading: HostPhotos.allowsReading)
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        HostPhotos.requestAccess { completion(Self.status($0, allowsReading: HostPhotos.allowsReading)) }
    }
}

/// The photos module: the contract, its results, its files, its callback
/// and its delegate.
public enum HostPhotosModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            PhotosProxy.descriptor, PhotoResultsProxy.descriptor, PhotoFileGrantProxy.descriptor,
            PhotoCallbackProxy.descriptor, PhotosDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        PhotosProxy.register(HostPhotos.self, in: registrar)
        PhotoResultsProxy.register(HostPhotoResults.self, in: registrar)
        PhotoFileGrantProxy.register(HostPhotoFile.self, in: registrar)
        PhotoCallbackProxy.registerInterface(in: registrar)
        PhotosDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.photoLibrary: PhotosPermission()]
    }
}
