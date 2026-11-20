import Dispatch
import DynamicDocuments
import DynamicFiles
import DynamicRuntime
import RuntimeABI
import RuntimeHost

/// A file or folder a host's picker gave, or one the app was opened with.
public struct HostDocument {

    /// An absolute path, which the host's process can open while the
    /// document is held.
    public var path: String

    public var kind: FileKind

    public var isWritable: Bool

    /// What the provider calls it; the path's last component when `nil`.
    public var name: String?

    /// A MIME type, where the provider gives one.
    public var contentType: String?

    /// Called on the main thread when the guest lets go of the document:
    /// where a host stops a security scope or closes a descriptor.
    public var release: (() -> Void)?

    public init(
        path: String,
        kind: FileKind = .file,
        isWritable: Bool = false,
        name: String? = nil,
        contentType: String? = nil,
        release: (() -> Void)? = nil
    ) {
        self.path = path
        self.kind = kind
        self.isWritable = isWritable
        self.name = name
        self.contentType = contentType
        self.release = release
    }

    /// The name to show: the provider's, or the path's last component.
    public var displayName: String {
        if let name {
            return name
        }
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// What became of a host's save picker.
public enum HostDocumentExport {

    /// Saved where the user said, and still reachable.
    case saved(HostDocument)

    /// Saved, and out of reach.
    case savedCopy

    case cancelled
}

/// What shows a host's pickers and remembers documents: the part of the
/// `Documents` contract that's the platform's own. Everything is called on
/// the main thread, and every completion is called on it, once.
public protocol DocumentPresenter: AnyObject {

    /// Shows the picker for opening files. `types` are MIME types, MIME
    /// groups and extensions, as the contract carries them; none means any
    /// file. Nothing picked means the user cancelled.
    func pick(types: [String], multiple: Bool, access: DocumentAccess, completion: @escaping (Result<[HostDocument], DocumentError>) -> Void)

    /// Shows the picker for a folder. `nil` means the user cancelled.
    func pickFolder(access: DocumentAccess, completion: @escaping (Result<HostDocument?, DocumentError>) -> Void)

    /// Shows the picker for saving, suggesting `name`, and copies the file
    /// at `source` to where the user says (`HostFiles.copy(file:to:)`
    /// where the platform's picker doesn't).
    func export(file source: String, name: String, completion: @escaping (Result<HostDocumentExport, DocumentError>) -> Void)

    /// Remembers a document, and answers with the string that names it.
    func bookmark(_ document: HostDocument, completion: @escaping (Result<String, DocumentError>) -> Void)

    func resolve(_ bookmark: String, completion: @escaping (Result<HostDocument, DocumentError>) -> Void)

    func forget(_ bookmark: String)
}

/// The `Documents` contract over a host's `DocumentPresenter`: what every
/// host with file paths shares.
///
/// It turns what the presenter gives into grants in `HostFiles`, so the
/// guest's `FileManager` and every contract that asks
/// `HostFiles.path(of:path:)` reach the document; ends each grant when the
/// guest lets go; shows one picker at a time; and keeps the documents the
/// app is opened with until the guest listens.
///
/// ```swift
/// HostDocuments.presenter = MyPickers()
/// HostDocumentsModule.register(in: runtime)
/// // When the platform opens the app with a file:
/// HostDocuments.open([HostDocument(path: path)])
/// ```
///
/// Main thread only.
public final class HostDocuments: Documents {

    /// The host's pickers. Without one, every picker fails with
    /// `unsupported`.
    nonisolated(unsafe) public static var presenter: (any DocumentPresenter)?

    /// Runs an answer on the main thread, after the call that asked has
    /// returned. The default is the main dispatch queue; a host with a
    /// loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }

    nonisolated(unsafe) private static var instance = HostDocuments()

    private var isShowing = false

    private var delegate: (any DocumentsDelegate)?

    /// Documents the app was opened with while nothing listened.
    private var waiting: [HostDocument] = []

    init() { }

    public static func shared() -> HostDocuments {
        instance
    }

    // MARK: Host side

    /// The app was opened with these: from the file manager, or another
    /// app. The guest hears now, or when it starts to listen.
    public static func open(_ documents: [HostDocument]) {
        guard !documents.isEmpty else { return }
        if let delegate = instance.delegate {
            delegate.didOpen(documents.map(HostDocumentGrant.init))
        } else {
            instance.waiting += documents
        }
    }

    /// Forgets the presenter, the delegate and what waits, for tests and
    /// for a host that starts the guest again.
    public static func reset() {
        presenter = nil
        instance = HostDocuments()
    }

    // MARK: Documents

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any DocumentCallback, _ answer: @escaping (any DocumentCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any DocumentCallback, _ error: DocumentError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// The presenter, when there is one and no picker is showing.
    private func presenterForPicker(_ callback: any DocumentCallback) -> (any DocumentPresenter)? {
        guard let presenter = Self.presenter else {
            Self.fail(callback, .unsupported)
            return nil
        }
        guard !isShowing else {
            Self.fail(callback, .busy)
            return nil
        }
        isShowing = true
        return presenter
    }

    public func pick(_ types: [String], multiple: Bool, access: Int32, callback: any DocumentCallback) {
        guard let presenter = presenterForPicker(callback) else { return }
        presenter.pick(types: types, multiple: multiple, access: DocumentAccess(rawValue: access) ?? .read) { [self] result in
            isShowing = false
            Self.later(callback) { callback in
                switch result {
                case .success(let documents):
                    // One file is all a picker for one may give.
                    let picked = multiple ? documents : Array(documents.prefix(1))
                    callback.didPick(picked.map(HostDocumentGrant.init))
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func pickFolder(_ access: Int32, callback: any DocumentCallback) {
        guard let presenter = presenterForPicker(callback) else { return }
        presenter.pickFolder(access: DocumentAccess(rawValue: access) ?? .read) { [self] result in
            isShowing = false
            Self.later(callback) { callback in
                switch result {
                case .success(let folder):
                    callback.didPick(folder.map { [HostDocumentGrant($0)] } ?? [])
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func export(_ directory: Int32, path: String, name: String, callback: any DocumentCallback) {
        let source: String
        do throws(FileError) {
            source = try HostFiles.path(of: directory, path: path)
        } catch {
            Self.fail(callback, error == .notPermitted ? .notPermitted : .notFound)
            return
        }
        guard HostFiles.kind(ofItemAt: source) == .file else {
            // Nothing there, or a folder: only a file is saved.
            Self.fail(callback, .notFound)
            return
        }
        guard let presenter = presenterForPicker(callback) else { return }
        presenter.export(file: source, name: name) { [self] result in
            isShowing = false
            Self.later(callback) { callback in
                switch result {
                case .success(.saved(let document)):
                    callback.didPick([HostDocumentGrant(document)])
                case .success(.savedCopy):
                    callback.didComplete()
                case .success(.cancelled):
                    callback.didPick([])
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func resolve(_ bookmark: String, callback: any DocumentCallback) {
        guard let presenter = Self.presenter else {
            Self.fail(callback, .unsupported)
            return
        }
        presenter.resolve(bookmark) { result in
            Self.later(callback) { callback in
                switch result {
                case .success(let document):
                    callback.didPick([HostDocumentGrant(document)])
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func forget(_ bookmark: String) {
        Self.presenter?.forget(bookmark)
    }

    public func setDelegate(_ delegate: (any DocumentsDelegate)?) {
        self.delegate = delegate
        guard delegate != nil, !waiting.isEmpty else { return }
        let held = MainThreadHeld(self)
        Self.deliver {
            // Still listening, and to the same documents object.
            guard let documents = held.take(), let delegate = documents.delegate, !documents.waiting.isEmpty else { return }
            let waiting = documents.waiting
            documents.waiting = []
            delegate.didOpen(waiting.map(HostDocumentGrant.init))
        }
    }
}

/// One document the guest holds: a grant in `HostFiles` for as long as this
/// object lives.
final class HostDocumentGrant: DocumentGrant {

    let document: HostDocument

    let granted: FileDirectory

    init(_ document: HostDocument) {
        self.document = document
        self.granted = HostFiles.grant(HostFiles.Grant(path: document.path, kind: document.kind, isWritable: document.isWritable))
    }

    deinit {
        HostFiles.revoke(granted)
        document.release?()
    }

    func directory() -> Int32 {
        granted.rawValue
    }

    func name() -> String {
        document.displayName
    }

    func kind() -> Int32 {
        document.kind.rawValue
    }

    func contentType() -> String? {
        document.contentType
    }

    func isWritable() -> Bool {
        document.isWritable
    }

    func bookmark(_ callback: any DocumentCallback) {
        guard let presenter = HostDocuments.presenter else {
            HostDocuments.deliver(callback) { $0.didFail(DocumentError.unsupported.rawValue) }
            return
        }
        presenter.bookmark(document) { result in
            HostDocuments.deliver(callback) { callback in
                switch result {
                case .success(let bookmark):
                    callback.didBookmark(bookmark)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }
}

extension HostDocuments {

    /// `later`, for the grant.
    static func deliver(_ callback: any DocumentCallback, _ answer: @escaping (any DocumentCallback) -> Void) {
        later(callback, answer)
    }
}

/// The documents module: `Documents`, its grants, and their callbacks.
public enum HostDocumentsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DocumentsProxy.descriptor, DocumentGrantProxy.descriptor, DocumentCallbackProxy.descriptor, DocumentsDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DocumentsProxy.register(HostDocuments.self, in: registrar)
        DocumentGrantProxy.register(HostDocumentGrant.self, in: registrar)
        DocumentCallbackProxy.registerInterface(in: registrar)
        DocumentsDelegateProxy.registerInterface(in: registrar)
    }

    /// The pickers ask the user themselves, so there's nothing to grant.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.userFiles: GrantedPermission()]
    }
}
