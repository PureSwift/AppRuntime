import DynamicFiles
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A file or folder the user gave the app: picked, exported to, or what the
/// app was opened with.
///
/// ```swift
/// if let photo = try await DocumentPicker().open([.image]) {
///     title = photo.name
///     let bytes = try await FileManager.default.contents(at: photo.path)
/// }
/// ```
///
/// The app reaches it while it holds this object. Releasing it ends the
/// access, and a `FilePath` kept past that fails with
/// `FileError.notPermitted`: hold the document for as long as the file is
/// open in the app.
///
/// It's guest-side only, over the `DocumentGrant` contract. The guest is
/// single-threaded (§6.4).
public final class Document: @unchecked Sendable {

    /// The host's grant. Its release is what ends the access.
    let grant: any DocumentGrant

    /// What the provider calls it, with its extension. For showing, not
    /// for finding it again: keep a `bookmark()` for that.
    public let name: String

    public let kind: FileKind

    /// From the provider where it says, and from the name's extension
    /// where it doesn't.
    public let contentType: ContentType?

    /// Whether a write can succeed.
    public let isWritable: Bool

    /// Where `FileManager`, and any contract that takes a `FilePath`,
    /// finds it. A file is the path itself; a folder's files are under it:
    /// `folder.path / "song.mp3"`.
    public let path: FilePath

    init(_ grant: any DocumentGrant) {
        self.grant = grant
        let name = grant.name()
        self.name = name
        // A kind from a newer host is some other thing that isn't a folder.
        self.kind = FileKind(rawValue: grant.kind()) ?? .file
        self.isWritable = grant.isWritable()
        self.path = FilePath(FileDirectory(rawValue: grant.directory()))
        if let type = grant.contentType(), !type.isEmpty {
            self.contentType = ContentType(mimeType: type)
        } else if kind == .directory {
            self.contentType = .folder
        } else {
            self.contentType = Self.fileExtension(of: name).flatMap(ContentType.init(filenameExtension:))
        }
    }

    public var isDirectory: Bool {
        kind == .directory
    }

    /// What follows the name's last dot, when something does.
    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return nil
        }
        let rest = name[name.index(after: dot)...]
        return rest.isEmpty ? nil : String(rest)
    }

    // MARK: Bookmarks

    /// Asks the host to remember the access, for another run. Fails with
    /// `unsupported` where the host can't, and with `limitReached` when it
    /// keeps no more.
    public func bookmark(completion: @escaping (Result<DocumentBookmark, DocumentError>) -> Void) {
        grant.bookmark(Receiver { outcome in
            if case .bookmark(let bookmark) = outcome {
                completion(.success(DocumentBookmark(rawValue: bookmark)))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// The document a bookmark was made from. Fails with `notFound` when
    /// it's gone, and with `notPermitted` when the access was taken back.
    public static func resolve(_ bookmark: DocumentBookmark, completion: @escaping (Result<Document, DocumentError>) -> Void) {
        DocumentsProxy.shared().resolve(bookmark.rawValue, callback: Receiver { outcome in
            if case .picked(let documents) = outcome, let document = documents.first {
                completion(.success(document))
            } else if case .picked = outcome {
                completion(.failure(.notFound))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Asks the host to remember the access, for another run.
    public nonisolated(nonsending) func bookmark() async throws(DocumentError) -> DocumentBookmark {
        try await documentResult { self.bookmark(completion: $0) }
    }

    /// The document a bookmark was made from.
    public nonisolated(nonsending) static func resolving(_ bookmark: DocumentBookmark) async throws(DocumentError) -> Document {
        try await documentResult { resolve(bookmark, completion: $0) }
    }
    #endif
}

#if !EMBEDDED_NO_CONCURRENCY
/// Waits for a completion handler. A cancelled task stops waiting with
/// `cancelled`; a picker that's showing stays up, and its result is
/// dropped.
nonisolated(nonsending) func documentResult<Value>(_ start: (@escaping (Result<Value, DocumentError>) -> Void) -> Void) async throws(DocumentError) -> Value {
    try await withCallback { (callback: Callback<Value, DocumentError>) in
        start { callback.resume(with: $0) }
    } onCancel: { callback in
        callback.resume(throwing: .cancelled)
    }
}
#endif

/// What a `DocumentCallback` was told.
enum DocumentOutcome {

    case picked([Document])
    case complete
    case bookmark(String)
    case failure(DocumentError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: DocumentError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
final class Receiver: DocumentCallback {

    private var finish: ((DocumentOutcome) -> Void)?

    init(_ finish: @escaping (DocumentOutcome) -> Void) {
        self.finish = finish
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: DocumentOutcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didPick(_ documents: [any DocumentGrant]) {
        answer(.picked(documents.map(Document.init)))
    }

    func didComplete() {
        answer(.complete)
    }

    func didBookmark(_ bookmark: String) {
        answer(.bookmark(bookmark))
    }

    func didFail(_ error: Int32) {
        answer(.failure(DocumentError(rawValue: error) ?? .unknown))
    }
}
