import DynamicRuntime

/// A media file's tags and artwork, read by the host without playing the
/// file (`Documentation/Contracts/MediaFiles.md`). App code uses
/// `MediaTags`, which wraps this contract.
///
/// It needs no capability: it reads what `Files` could, and plays nothing.
/// Each read is answered once, through its callback, on the main thread.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `AVURLAsset`'s `commonMetadata` and `duration` |
/// | Android | `MediaMetadataRetriever` |
/// | Linux | GStreamer's `GstDiscoverer` |
/// | Browser | none: it answers `unavailable` |
@DynamicRuntime("org.pureswift.media.Metadata")
public protocol MediaMetadata: AnyObject {

    static func shared() -> Self

    /// Reads the file `Files` names by `directory`, a `FileDirectory` raw
    /// value, and `path`. With `artwork`, the cover's bytes too.
    func read(_ directory: Int32, path: String, artwork: Bool, callback: MediaMetadataCallback)
}

/// The answer to one `MediaMetadata.read`. Called once, on the main thread.
@DynamicCallback("org.pureswift.media.MetadataCallback")
public protocol MediaMetadataCallback: AnyObject {

    /// `tags`: a key, then its value, then the next key. `artwork` is an
    /// image file's bytes, empty without one or when it wasn't asked for,
    /// and `artworkType` its MIME type.
    func didRead(_ tags: [String], artwork: [UInt8], artworkType: String)

    /// `code` is a `MediaError.Code` raw value.
    func didFail(_ code: Int32, message: String)
}
