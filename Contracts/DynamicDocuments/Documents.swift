import DynamicRuntime

/// The user's files: the platform's pickers, the documents an app is opened
/// with, and remembered access (`Documentation/Contracts/Documents.md`). App
/// code uses `DocumentPicker` and `Document`, which wrap this contract.
///
/// What the user picks arrives as a `DocumentGrant`, whose `directory()` is
/// a directory the `Files` contract takes for as long as the grant lives.
/// Every operation completes through its `callback`, which the host holds
/// until it has called exactly one of its methods, on the main thread.
///
/// `.userFiles` prompts for nothing: the user's choice of a file is the
/// permission. It tells the packager and the sandbox that the app shows
/// pickers.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `UIDocumentPickerViewController` |
/// | macOS | `NSOpenPanel`, `NSSavePanel` |
/// | Android | the Storage Access Framework |
/// | Linux | the picker service the file manager owns |
/// | Browser | `showOpenFilePicker`, or `<input type="file">` |
@DynamicRuntime("org.pureswift.documents.Documents", requires: .userFiles)
public protocol Documents: AnyObject {

    static func shared() -> Self

    /// Asks the user for files. `types` are MIME types (`image/png`), MIME
    /// groups (`image/*`) and extensions (`.gpx`); none means any file.
    /// `access` is a `DocumentAccess` raw value. Answers `didPick`, with
    /// nothing if the user cancelled.
    func pick(_ types: [String], multiple: Bool, access: Int32, callback: DocumentCallback)

    /// Asks the user for photos or videos from their library, with the
    /// system's photo picker (`Documentation/Contracts/Photos.md`).
    /// `kinds`: bits, 1 images, 2 videos; none means both. Answers
    /// `didPick`, with nothing if the user cancelled. Each pick is
    /// read-only, a copy the host holds while the guest holds the grant,
    /// and can't be bookmarked. A host with no photo picker shows its
    /// document picker, for images and videos.
    func pickPhotos(_ kinds: Int32, multiple: Bool, callback: DocumentCallback)

    /// Asks the user for a folder. Answers `didPick` with it, or with
    /// nothing if the user cancelled.
    func pickFolder(_ access: Int32, callback: DocumentCallback)

    /// Asks the user where to save a file, suggesting `name`, and copies
    /// the file at `path` in `directory` there. Answers `didPick` with the
    /// copy, `didPick` with nothing if the user cancelled, or `didComplete`
    /// when it's saved and the host can't reach it again.
    func export(_ directory: Int32, path: String, name: String, callback: DocumentCallback)

    /// The document a bookmark was made from. Answers `didPick` with it.
    func resolve(_ bookmark: String, callback: DocumentCallback)

    /// Gives up a bookmark's access. Fine if the host doesn't know it.
    func forget(_ bookmark: String)

    /// Where documents the app is opened with go. The host keeps those
    /// that arrive while there's no delegate, and reports them when one is
    /// set.
    func setDelegate(_ delegate: DocumentsDelegate?)
}

public extension Documents {

    /// What a host with no photo picker does: its document picker, for
    /// images and videos. A host that implements `Documents` itself, and
    /// has a photo picker, implements this.
    func pickPhotos(_ kinds: Int32, multiple: Bool, callback: DocumentCallback) {
        pick(DocumentPicker.photoForms(kinds), multiple: multiple, access: DocumentAccess.read.rawValue, callback: callback)
    }
}

/// One file or folder the user gave the app. Releasing it ends the access:
/// its directory answers `notPermitted` from then on.
@DynamicRuntime("org.pureswift.documents.Grant")
public protocol DocumentGrant: AnyObject {

    /// The directory `Files` takes for this document while the grant lives:
    /// 256 or more, and not used again in the same run. A file is the
    /// directory's empty path.
    func directory() -> Int32

    /// What the provider calls it, with its extension. For showing.
    func name() -> String

    /// A `FileKind` raw value.
    func kind() -> Int32

    /// A MIME type, where the provider gives one.
    func contentType() -> String?

    func isWritable() -> Bool

    /// Asks the host to remember the access. Answers `didBookmark`.
    func bookmark(_ callback: DocumentCallback)
}
