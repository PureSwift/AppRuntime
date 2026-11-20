import DynamicFiles
import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Asks the user for files, a folder, or a place to save: the platform's
/// own picker, over the app's window.
///
/// ```swift
/// let picker = DocumentPicker()
/// if let photo = try await picker.open([.image]) { … }
/// let notes = try await picker.open([.plainText], allowsMultiple: true, access: .readWrite)
/// if let library = try await picker.openFolder() { … }
/// ```
///
/// - Cancelling isn't an error: it gives `nil`, or no documents.
/// - Call it from a user action. A browser refuses otherwise, with
///   `notAllowed`.
/// - One picker shows at a time; a second fails with `busy`.
///
/// Each call has a completion-handler form, for code that isn't `async`
/// and for slices built without the concurrency runtime.
///
/// It's guest-side only, over the `Documents` contract. The guest is
/// single-threaded (§6.4).
public final class DocumentPicker: @unchecked Sendable {

    /// The host's documents, made when first used.
    private var made: (any Documents)?

    public init() { }

    private var documents: any Documents {
        if let made {
            return made
        }
        let documents = DocumentsProxy.shared()
        made = documents
        return documents
    }

    // MARK: Completion handlers

    /// Asks for files of `types`; none means any file. No documents if the
    /// user cancelled.
    public func open(
        _ types: [ContentType] = [],
        allowsMultiple: Bool,
        access: DocumentAccess = .read,
        completion: @escaping (Result<[Document], DocumentError>) -> Void
    ) {
        documents.pick(ContentType.wireForms(types), multiple: allowsMultiple, access: access.rawValue, callback: Receiver { outcome in
            if case .picked(let documents) = outcome {
                completion(.success(documents))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Asks for one file; `nil` if the user cancelled.
    public func open(
        _ types: [ContentType] = [],
        access: DocumentAccess = .read,
        completion: @escaping (Result<Document?, DocumentError>) -> Void
    ) {
        open(types, allowsMultiple: false, access: access) { result in
            completion(result.map { $0.first })
        }
    }

    /// Asks for a folder; `nil` if the user cancelled. The document
    /// reaches everything in it.
    public func openFolder(access: DocumentAccess = .read, completion: @escaping (Result<Document?, DocumentError>) -> Void) {
        documents.pickFolder(access.rawValue, callback: Receiver { outcome in
            if case .picked(let documents) = outcome {
                completion(.success(documents.first))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Asks where to save `file`, and copies it there. `file` is one of the
    /// app's own files, or another document; `suggestedName` is its own
    /// name unless given.
    public func export(
        _ file: FilePath,
        suggestedName: String? = nil,
        completion: @escaping (Result<DocumentExport, DocumentError>) -> Void
    ) {
        let name = suggestedName ?? file.lastComponent
        documents.export(file.directory.rawValue, path: file.path, name: name, callback: Receiver { outcome in
            switch outcome {
            case .picked(let documents):
                completion(.success(documents.first.map(DocumentExport.saved) ?? .cancelled))
            case .complete:
                completion(.success(.savedCopy))
            default:
                completion(.failure(outcome.error))
            }
        })
    }

    // MARK: Opened with a document

    /// Hears of the documents the app is opened with: from the file
    /// manager, or from another app. Those the app was launched with wait
    /// in the host until a handler is set. `nil` stops hearing, and the
    /// host keeps what arrives.
    public static func onOpen(_ handler: (([Document]) -> Void)?) {
        opening.generation &+= 1
        #if !EMBEDDED_NO_CONCURRENCY
        opening.stream?.finish()
        opening.stream = nil
        #endif
        listen(handler)
    }

    private static func listen(_ handler: (([Document]) -> Void)?) {
        opening.handler = handler
        DocumentsProxy.shared().setDelegate(handler == nil ? nil : opening)
    }

    nonisolated(unsafe) static let opening = OpenedDocuments()

    // MARK: Async

    #if !EMBEDDED_NO_CONCURRENCY
    /// Asks for files of `types`; none means any file. No documents if the
    /// user cancelled.
    public nonisolated(nonsending) func open(
        _ types: [ContentType] = [],
        allowsMultiple: Bool,
        access: DocumentAccess = .read
    ) async throws(DocumentError) -> [Document] {
        try await documentResult { self.open(types, allowsMultiple: allowsMultiple, access: access, completion: $0) }
    }

    /// Asks for one file; `nil` if the user cancelled.
    public nonisolated(nonsending) func open(_ types: [ContentType] = [], access: DocumentAccess = .read) async throws(DocumentError) -> Document? {
        try await documentResult { self.open(types, access: access, completion: $0) }
    }

    /// Asks for a folder; `nil` if the user cancelled.
    public nonisolated(nonsending) func openFolder(access: DocumentAccess = .read) async throws(DocumentError) -> Document? {
        try await documentResult { self.openFolder(access: access, completion: $0) }
    }

    /// Asks where to save `file`, and copies it there.
    public nonisolated(nonsending) func export(_ file: FilePath, suggestedName: String? = nil) async throws(DocumentError) -> DocumentExport {
        try await documentResult { self.export(file, suggestedName: suggestedName, completion: $0) }
    }

    /// The documents the app is opened with, as they arrive. Those the app
    /// was launched with wait in the host until this is first read.
    ///
    /// ```swift
    /// for await documents in DocumentPicker.opened {
    ///     open(documents)
    /// }
    /// ```
    ///
    /// One stream at a time: reading it again finishes the one before, and
    /// so does `onOpen`. When the stream is released or its task is
    /// cancelled, the host keeps what arrives.
    public static var opened: EventStream<[Document], Never> {
        let (stream, continuation) = EventStream<[Document], Never>.makeStream()
        opening.generation &+= 1
        let generation = opening.generation
        opening.stream?.finish()
        opening.stream = continuation
        continuation.onTermination = {
            guard opening.generation == generation else { return }
            opening.stream = nil
            listen(nil)
        }
        listen { continuation.yield($0) }
        return stream
    }
    #endif
}

/// The delegate behind `DocumentPicker.opened` and `onOpen`.
final class OpenedDocuments: DocumentsDelegate {

    var handler: (([Document]) -> Void)?

    #if !EMBEDDED_NO_CONCURRENCY
    var stream: EventStream<[Document], Never>.Continuation?
    #endif

    var generation = 0

    func didOpen(_ documents: [any DocumentGrant]) {
        handler?(documents.map(Document.init))
    }
}
