import DynamicRuntime

/// The photos and videos the system keeps for the user
/// (`Documentation/Contracts/Photos.md`). App code uses `PhotoLibrary`,
/// which wraps this contract.
///
/// The library is the system's. An app adds to it, browses it and deletes
/// from it; it doesn't change a photo. No picture crosses to the guest: a
/// `Photo` node shows an asset, and an asset's original is a file `Files`
/// reaches. Every operation completes through its `callback`, which the
/// host holds until it has called exactly one of its methods, on the main
/// thread.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `PHPhotoLibrary` |
/// | Android | `MediaStore` |
/// | Linux | the user's Pictures and Videos folders |
/// | Browser | a download, for adding; nothing else |
@DynamicRuntime("org.pureswift.photos.Photos", requires: .photoLibrary)
public protocol Photos: AnyObject {

    static func shared() -> Self

    /// A `PhotoLibraryAccess` raw value. Never asks.
    func access() -> Int32

    /// Asks the user if they haven't decided, for what the manifest
    /// declares. Answered by `didChangeAccess`.
    func requestAccess(_ callback: PhotoCallback)

    /// Told after any change to the library. `nil` stops it.
    func setDelegate(_ delegate: PhotosDelegate?)

    /// Copies a file into the library. A file as `Files` names it; `kind`
    /// is a `PhotoKind` raw value. Answered by `didAdd`.
    func add(_ directory: Int32, path: String, kind: Int32, callback: PhotoCallback)

    /// Newest first. `kind`: 0 both, or a `PhotoKind` raw value. `album`
    /// empty: the whole library. Answered by `didFetch`.
    func fetch(_ kind: Int32, album: String, callback: PhotoCallback)

    /// Answered by `didFindAsset`.
    func asset(_ identifier: String, callback: PhotoCallback)

    /// Answered by `didListAlbums`.
    func albums(_ callback: PhotoCallback)

    /// The asset's original, as a file. Answered by `didOpenFile`.
    func file(_ identifier: String, callback: PhotoCallback)

    /// Asks the user, then deletes all of them or none. Answered by
    /// `didComplete`.
    func delete(_ identifiers: [String], callback: PhotoCallback)
}

/// One fetch's results: the library as it was when the fetch was made.
/// The host's object; releasing it lets the host forget the fetch.
@DynamicRuntime("org.pureswift.photos.Results")
public protocol PhotoResults: AnyObject {

    func count() -> Int32

    /// The assets from `start`, `count` of them at most: fewer, or none,
    /// past the end, and for those that have gone. Answered by
    /// `didListAssets`.
    func assets(_ start: Int32, count: Int32, callback: PhotoCallback)
}

/// One original, as a file. Releasing it ends the access: its directory
/// answers `notPermitted` from then on, and the host removes its copy.
@DynamicRuntime("org.pureswift.photos.File")
public protocol PhotoFileGrant: AnyObject {

    /// The directory `Files` takes for this file while the object lives:
    /// 256 or more. The file is the directory's empty path.
    func directory() -> Int32

    /// The file's own name, where it has one; empty where it hasn't.
    func name() -> String

    /// A MIME type: `image/heic`, `video/quicktime`.
    func contentType() -> String
}

/// One operation's answer, from the host. Called once, on the main thread.
///
/// An asset is seven strings: identifier, kind, creation date in
/// milliseconds since 1970, width, height, duration in milliseconds, and
/// `1` for a favourite. Numbers are decimal.
@DynamicCallback("org.pureswift.photos.Callback")
public protocol PhotoCallback: AnyObject {

    func didComplete()

    /// A `PhotoLibraryAccess` raw value.
    func didChangeAccess(_ access: Int32)

    /// The new asset's seven strings; none for an app that may only add.
    func didAdd(_ fields: [String])

    func didFetch(_ results: PhotoResults)

    /// Seven strings for each asset.
    func didListAssets(_ fields: [String])

    /// Seven strings, or none when the asset is gone.
    func didFindAsset(_ fields: [String])

    /// Four strings for each album: identifier, title, count, and its
    /// `PhotoAlbum.Kind` raw value.
    func didListAlbums(_ fields: [String])

    func didOpenFile(_ file: PhotoFileGrant)

    /// A `PhotoLibraryError` raw value.
    func didFail(_ error: Int32)
}

/// What a library tells the app, from the host. Called on the main thread.
@DynamicCallback("org.pureswift.photos.Delegate")
public protocol PhotosDelegate: AnyObject {

    /// Something changed: a photo taken, a sync, another app, or this
    /// app. Not what.
    func didChange()
}
