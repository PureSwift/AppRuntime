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
/// if let scan = try await picker.open([.image]) { … }
/// if let photo = try await picker.open([.image], from: .photoLibrary) { … }
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
    ///
    /// With `from: .photoLibrary` the system's photo picker shows the
    /// user's photos and videos instead of their files: `types` then says
    /// images, videos or both, and what's picked is read-only whatever
    /// `access` says.
    public func open(
        _ types: [ContentType] = [],
        from source: DocumentSource = .files,
        allowsMultiple: Bool,
        access: DocumentAccess = .read,
        completion: @escaping (Result<[Document], DocumentError>) -> Void
    ) {
        let receiver = Receiver { outcome in
            if case .picked(let documents) = outcome {
                completion(.success(documents))
            } else {
                completion(.failure(outcome.error))
            }
        }
        switch source {
        case .files:
            documents.pick(ContentType.wireForms(types), multiple: allowsMultiple, access: access.rawValue, callback: receiver)
        case .photoLibrary:
            // A host with no photo picker shows its document picker, for
            // images and videos: `pickPhotos`' default.
            documents.pickPhotos(Self.photoKinds(types), multiple: allowsMultiple, callback: receiver)
        }
    }

    /// Asks for one file; `nil` if the user cancelled.
    public func open(
        _ types: [ContentType] = [],
        from source: DocumentSource = .files,
        access: DocumentAccess = .read,
        completion: @escaping (Result<Document?, DocumentError>) -> Void
    ) {
        open(types, from: source, allowsMultiple: false, access: access) { result in
            completion(result.map { $0.first })
        }
    }

    /// What a photo picker is asked for, from the types an app names:
    /// bits, 1 images, 2 videos. Types that are neither ask for both.
    static func photoKinds(_ types: [ContentType]) -> Int32 {
        var kinds: Int32 = 0
        for type in types {
            if type.conforms(to: .image) {
                kinds |= 1
            }
            if type.conforms(to: .movie) {
                kinds |= 2
            }
        }
        return kinds == 0 ? 3 : kinds
    }

    /// The document picker's types for the same kinds. Neither bit is
    /// both.
    static func photoForms(_ kinds: Int32) -> [String] {
        let both = kinds & 3 == 0
        var forms: [String] = []
        if both || kinds & 1 != 0 {
            forms.append("image/*")
        }
        if both || kinds & 2 != 0 {
            forms.append("video/*")
        }
        return forms
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
        from source: DocumentSource = .files,
        allowsMultiple: Bool,
        access: DocumentAccess = .read
    ) async throws(DocumentError) -> [Document] {
        try await documentResult { self.open(types, from: source, allowsMultiple: allowsMultiple, access: access, completion: $0) }
    }

    /// Asks for one file; `nil` if the user cancelled.
    public nonisolated(nonsending) func open(
        _ types: [ContentType] = [],
        from source: DocumentSource = .files,
        access: DocumentAccess = .read
    ) async throws(DocumentError) -> Document? {
        try await documentResult { self.open(types, from: source, access: access, completion: $0) }
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
