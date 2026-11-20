import Foundation
import Testing
import DynamicDocuments
import DynamicFiles
import DynamicRuntime
import RuntimeHost
import RuntimeNative
@testable import RuntimeDocuments

/// A host's pickers, answered by the test: each call waits for `answer`.
final class TestPresenter: DocumentPresenter {

    var calls: [String] = []

    /// What the open pickers that are showing are waiting to hear.
    var picks: [(Result<[HostDocument], DocumentError>) -> Void] = []
    var folders: [(Result<HostDocument?, DocumentError>) -> Void] = []
    var exports: [(source: String, completion: (Result<HostDocumentExport, DocumentError>) -> Void)] = []

    var bookmarks: [String: HostDocument] = [:]

    var bookmarkLimit = 2

    func pick(types: [String], multiple: Bool, access: DocumentAccess, completion: @escaping (Result<[HostDocument], DocumentError>) -> Void) {
        calls.append("pick \(types) \(multiple) \(access)")
        picks.append(completion)
    }

    func pickFolder(access: DocumentAccess, completion: @escaping (Result<HostDocument?, DocumentError>) -> Void) {
        calls.append("pickFolder \(access)")
        folders.append(completion)
    }

    func export(file source: String, name: String, completion: @escaping (Result<HostDocumentExport, DocumentError>) -> Void) {
        calls.append("export \(name)")
        exports.append((source, completion))
    }

    func bookmark(_ document: HostDocument, completion: @escaping (Result<String, DocumentError>) -> Void) {
        guard bookmarks.count < bookmarkLimit else {
            completion(.failure(.limitReached))
            return
        }
        let token = "token-\(bookmarks.count + 1)"
        bookmarks[token] = document
        completion(.success(token))
    }

    func resolve(_ bookmark: String, completion: @escaping (Result<HostDocument, DocumentError>) -> Void) {
        guard let document = bookmarks[bookmark] else {
            completion(.failure(.notPermitted))
            return
        }
        guard HostFiles.kind(ofItemAt: document.path) != nil else {
            completion(.failure(.notFound))
            return
        }
        completion(.success(document))
    }

    func forget(_ bookmark: String) {
        calls.append("forget \(bookmark)")
        bookmarks[bookmark] = nil
    }
}

/// `HostDocuments` over a test's pickers and real files in a temporary
/// directory, driven from the guest's `DocumentPicker` and `FileManager`
/// through the runtime.
///
/// Serialized: `HostFiles`, `HostDocuments` and the native runtime are
/// shared.
@Suite(.serialized) final class RuntimeDocumentsTests {

    let root: URL

    /// The user's own files, outside the app's directories.
    let home: URL

    let presenter = TestPresenter()

    let picker = DocumentPicker()

    let files = DynamicFiles.FileManager()

    init() throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("RuntimeDocumentsTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = root.appendingPathComponent("Home")
        try manager.createDirectory(at: home.appendingPathComponent("Music/Albums"), withIntermediateDirectories: true)
        try Data("a photo".utf8).write(to: home.appendingPathComponent("photo.jpg"))
        try Data("notes".utf8).write(to: home.appendingPathComponent("notes.txt"))
        try Data("one".utf8).write(to: home.appendingPathComponent("Music/Albums/one.mp3"))
        try Data("two".utf8).write(to: home.appendingPathComponent("Music/two.mp3"))

        let native = NativeRuntime.shared
        native.capabilities = nil
        let container = root.appendingPathComponent("Container")
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .caches: container.appendingPathComponent("Caches").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostDocuments.reset()
        HostDocuments.presenter = presenter
        HostDocuments.deliver = { $0() }
        HostDocumentsModule.register(in: native)
        DocumentPicker.onOpen(nil)
    }

    deinit {
        HostDocuments.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func path(_ name: String) -> String {
        home.appendingPathComponent(name).path
    }

    func onDisk(_ name: String) -> String? {
        (try? Data(contentsOf: home.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Reads a file through the guest's `FileManager`.
    func read(_ path: FilePath) -> Result<String, FileError> {
        var result: Result<[UInt8], FileError>?
        files.contents(at: path) { result = $0 }
        return (result ?? .failure(.unknown)).map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ text: String, to path: FilePath) -> FileError? {
        var result: Result<Void, FileError>?
        files.write(Array(text.utf8), to: path) { result = $0 }
        if case .failure(let error) = result { return error }
        return result == nil ? .unknown : nil
    }

    func failure<Value>(_ result: Result<Value, DocumentError>?) -> DocumentError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Picks one file, as the user would.
    func pick(_ name: String, writable: Bool = false, release: (() -> Void)? = nil) throws -> Document {
        var result: Result<Document?, DocumentError>?
        picker.open(access: writable ? .readWrite : .read) { result = $0 }
        presenter.picks.removeLast()(.success([HostDocument(path: path(name), isWritable: writable, release: release)]))
        return try #require(try result?.get())
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostDocumentsModule.contracts.map(\.name) == [
            "org.pureswift.documents.Documents", "org.pureswift.documents.Grant",
            "org.pureswift.documents.Callback", "org.pureswift.documents.Delegate",
        ])
        #expect(HostDocumentsModule.isUsed(by: ["org.pureswift.documents.Documents"]))
        #expect(HostDocumentsModule.permissionProviders()[.userFiles]?.status() == .granted, "the picker asks, not a prompt")
    }

    // MARK: Opening

    @Test func aPickedFileIsReadThroughFiles() throws {
        let photo = try pick("photo.jpg")
        #expect(presenter.calls == ["pick [] false read"])
        #expect(photo.name == "photo.jpg")
        #expect(photo.contentType == .jpeg, "from its name: the host gave no type")
        #expect(!photo.isWritable)
        #expect(photo.path.directory.isGrant)
        #expect(read(photo.path) == .success("a photo"))
        #expect(write("changed", to: photo.path) == .readOnly)
        #expect(onDisk("photo.jpg") == "a photo")
        #expect(read(photo.path / "inside") == .failure(.notDirectory), "a file has nothing under it")

        // A copy comes into the container; the picked file stays.
        var copied: Result<Void, FileError>?
        files.copyItem(at: photo.path, to: .caches / "photo.jpg") { copied = $0 }
        #expect((try? copied?.get()) != nil)
        #expect(read(.caches / "photo.jpg") == .success("a photo"))
        var removed: Result<Void, FileError>?
        files.removeItem(at: photo.path) { removed = $0 }
        #expect(throws: FileError.readOnly) { try removed?.get() }
    }

    @Test func lettingGoEndsTheAccess() throws {
        var released = 0
        var document: Document? = try pick("notes.txt", writable: true) { released += 1 }
        let path = try #require(document?.path)
        #expect(read(path) == .success("notes"))
        #expect(HostFiles.grant(for: path.directory) == HostFiles.Grant(path: self.path("notes.txt"), kind: .file, isWritable: true))
        document = nil
        #expect(released == 1, "the host stops its security scope, or closes its descriptor")
        #expect(HostFiles.grant(for: path.directory) == nil)
        #expect(read(path) == .failure(.notPermitted))
        #expect(write("late", to: path) == .notPermitted)
        #expect(onDisk("notes.txt") == "notes")
    }

    @Test func aWritableDocumentIsSavedInPlace() throws {
        let document = try pick("notes.txt", writable: true)
        #expect(document.isWritable)
        #expect(write("new notes", to: document.path) == nil)
        #expect(onDisk("notes.txt") == "new notes")
        #expect(try Foundation.FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == ["Music", "notes.txt", "photo.jpg"],
                "no temporary file stays behind")
        var removed: Result<Void, FileError>?
        files.removeItem(at: document.path) { removed = $0 }
        #expect(throws: FileError.invalidPath) { try removed?.get() }
        #expect(onDisk("notes.txt") == "new notes", "what the user picked stays where it is")
        files.moveItem(at: document.path, to: .documents / "taken.txt") { removed = $0 }
        #expect(throws: FileError.invalidPath) { try removed?.get() }
    }

    @Test func aPickerForOneGivesOne() throws {
        var one: Result<[Document], DocumentError>?
        picker.open([.image], allowsMultiple: false) { one = $0 }
        presenter.picks.removeLast()(.success([HostDocument(path: path("photo.jpg")), HostDocument(path: path("notes.txt"))]))
        #expect(try one?.get().map(\.name) == ["photo.jpg"])

        var many: Result<[Document], DocumentError>?
        picker.open([.image, .plainText], allowsMultiple: true, access: .readWrite) { many = $0 }
        #expect(presenter.calls.last == #"pick ["image/*", "text/plain"] true readWrite"#)
        presenter.picks.removeLast()(.success([
            HostDocument(path: path("photo.jpg"), name: "Holiday", contentType: "image/jpeg"),
            HostDocument(path: path("notes.txt")),
        ]))
        let documents = try #require(try many?.get())
        #expect(documents.map(\.name) == ["Holiday", "notes.txt"], "the provider's name, where it has one")
        #expect(documents[0].contentType == .jpeg)
        #expect(documents[0].path != documents[1].path)

        var cancelled: Result<[Document], DocumentError>?
        picker.open(allowsMultiple: true) { cancelled = $0 }
        presenter.picks.removeLast()(.success([]))
        #expect(try cancelled?.get().isEmpty == true)
    }

    @Test func aFolderIsADirectory() throws {
        var result: Result<Document?, DocumentError>?
        picker.openFolder(access: .readWrite) { result = $0 }
        #expect(presenter.calls == ["pickFolder readWrite"])
        presenter.folders.removeLast()(.success(HostDocument(path: path("Music"), kind: .directory, isWritable: true)))
        let library = try #require(try result?.get())
        #expect(library.name == "Music" && library.isDirectory && library.contentType == .folder)

        var names: Result<[String], FileError>?
        files.contentsOfDirectory(at: library.path) { names = $0 }
        #expect(names == .success(["Albums/", "two.mp3"]))
        #expect(read(library.path / "Albums/one.mp3") == .success("one"))
        #expect(write("three", to: library.path / "New/three.mp3") == nil)
        #expect(onDisk("Music/New/three.mp3") == "three")
        #expect(read(library.path / "../notes.txt") == .failure(.invalidPath), "nothing outside it")

        var removed: Result<Void, FileError>?
        files.removeItem(at: library.path / "New") { removed = $0 }
        #expect(onDisk("Music/New/three.mp3") == nil)
        files.removeItem(at: library.path) { removed = $0 }
        #expect(throws: FileError.invalidPath) { try removed?.get() }
        #expect(onDisk("Music/two.mp3") == "two", "the folder itself, and what's in it, stays")

        var cancelled: Result<Document?, DocumentError>?
        picker.openFolder { cancelled = $0 }
        presenter.folders.removeLast()(.success(nil))
        #expect(try cancelled?.get() == nil && cancelled != nil)
    }

    @Test func onePickerShowsAtATime() throws {
        var first: Result<[Document], DocumentError>?
        var second: Result<Document?, DocumentError>?
        picker.open(allowsMultiple: true) { first = $0 }
        picker.openFolder { second = $0 }
        #expect(failure(second) == .busy)
        #expect(presenter.calls == ["pick [] true read"], "the second never showed")
        var export: Result<DocumentExport, DocumentError>?
        #expect(write("x", to: .temporary / "x.txt") == nil)
        picker.export(.temporary / "x.txt") { export = $0 }
        #expect(failure(export) == .busy)

        presenter.picks.removeLast()(.failure(.notAllowed))
        #expect(failure(first) == .notAllowed)
        picker.openFolder { second = $0 }
        #expect(presenter.folders.count == 1, "and then the next may show")
    }

    @Test func aHostWithNoPickersSaysSo() {
        HostDocuments.presenter = nil
        var opened: Result<[Document], DocumentError>?
        picker.open(allowsMultiple: true) { opened = $0 }
        #expect(failure(opened) == .unsupported)
        var resolved: Result<Document, DocumentError>?
        Document.resolve(DocumentBookmark(rawValue: "token-1")) { resolved = $0 }
        #expect(failure(resolved) == .unsupported)
    }

    // MARK: Saving

    @Test func anExportCopiesTheFileWhereTheUserSays() throws {
        #expect(write("a draft", to: .temporary / "Untitled.txt") == nil)
        var result: Result<DocumentExport, DocumentError>?
        picker.export(.temporary / "Untitled.txt", suggestedName: "Essay.txt") { result = $0 }
        #expect(presenter.calls == ["export Essay.txt"])
        let export = presenter.exports.removeLast()
        #expect(HostFiles.kind(ofItemAt: export.source) == .file, "the host is told where the file is")
        try HostFiles.copy(file: export.source, to: path("Essay.txt"))
        export.completion(.success(.saved(HostDocument(path: path("Essay.txt"), isWritable: true))))
        let saved = try #require(try result?.get().document)
        #expect(onDisk("Essay.txt") == "a draft")
        #expect(saved.name == "Essay.txt")

        // From here a save writes the document itself.
        #expect(write("a second draft", to: saved.path) == nil)
        #expect(onDisk("Essay.txt") == "a second draft")

        // A document can be exported too, and an export may leave nothing to hold.
        picker.export(saved.path, suggestedName: "Copy.txt") { result = $0 }
        let copy = presenter.exports.removeLast()
        #expect(copy.source == path("Essay.txt"))
        copy.completion(.success(.savedCopy))
        guard case .success(.savedCopy) = result else {
            Issue.record("saved a copy")
            return
        }
        picker.export(.temporary / "Untitled.txt") { result = $0 }
        #expect(presenter.calls.last == "export Untitled.txt")
        presenter.exports.removeLast().completion(.success(.cancelled))
        guard case .success(.cancelled) = result else {
            Issue.record("cancelled")
            return
        }
    }

    @Test func onlyAFileThatIsThereIsExported() throws {
        var result: Result<DocumentExport, DocumentError>?
        picker.export(.temporary / "none.txt") { result = $0 }
        #expect(failure(result) == .notFound)
        var made: Result<Void, FileError>?
        files.createDirectory(at: .documents / "folder") { made = $0 }
        #expect((try? made?.get()) != nil)
        picker.export(.documents / "folder") { result = $0 }
        #expect(failure(result) == .notFound, "a folder isn't saved")
        picker.export(FilePath(FileDirectory(rawValue: 9999))) { result = $0 }
        #expect(failure(result) == .notPermitted, "a document the app doesn't hold")
        #expect(presenter.calls.isEmpty, "no picker showed")
    }

    // MARK: Bookmarks

    @Test func aBookmarkBringsTheDocumentBack() throws {
        var document: Document? = try pick("notes.txt", writable: true)
        var bookmark: Result<DocumentBookmark, DocumentError>?
        document?.bookmark { bookmark = $0 }
        let token = try #require(try bookmark?.get())
        let first = try #require(document?.path)
        document = nil
        #expect(read(first) == .failure(.notPermitted))

        var resolved: Result<Document, DocumentError>?
        Document.resolve(token) { resolved = $0 }
        let again = try #require(try resolved?.get())
        #expect(again.name == "notes.txt" && again.isWritable)
        #expect(again.path != first, "a new grant, with a directory of its own")
        #expect(read(again.path) == .success("notes"))

        // Gone, and then forgotten.
        try Foundation.FileManager.default.removeItem(atPath: path("notes.txt"))
        Document.resolve(token) { resolved = $0 }
        #expect(failure(resolved) == .notFound)
        token.forget()
        #expect(presenter.calls.last == "forget token-1")
        Document.resolve(token) { resolved = $0 }
        #expect(failure(resolved) == .notPermitted)
    }

    @Test func aHostKeepsOnlySoManyBookmarks() throws {
        presenter.bookmarkLimit = 1
        let photo = try pick("photo.jpg")
        let notes = try pick("notes.txt")
        var bookmark: Result<DocumentBookmark, DocumentError>?
        photo.bookmark { bookmark = $0 }
        #expect(failure(bookmark) == nil)
        notes.bookmark { bookmark = $0 }
        #expect(failure(bookmark) == .limitReached)
    }

    // MARK: Opened with a document

    @Test func documentsTheAppIsOpenedWithWaitForTheGuest() throws {
        var released = 0
        HostDocuments.open([HostDocument(path: path("photo.jpg")) { released += 1 }])
        HostDocuments.open([])
        HostDocuments.open([HostDocument(path: path("notes.txt"), isWritable: true)])
        #expect(released == 0, "nothing is granted, or let go, while they wait")

        var opened: [[Document]] = []
        DocumentPicker.onOpen { opened.append($0) }
        #expect(opened.map { $0.map(\.name) } == [["photo.jpg", "notes.txt"]], "what the app was launched with, at once")
        #expect(read(opened[0][0].path) == .success("a photo"))

        HostDocuments.open([HostDocument(path: path("Music"), kind: .directory)])
        #expect(opened.count == 2 && opened[1][0].isDirectory, "and what arrives while it listens")

        DocumentPicker.onOpen(nil)
        HostDocuments.open([HostDocument(path: path("photo.jpg"))])
        #expect(opened.count == 2)
        DocumentPicker.onOpen { opened.append($0) }
        #expect(opened.count == 3, "kept while nothing listened")

        opened = []
        #expect(released == 1)
        DocumentPicker.onOpen(nil)
    }

    /// The configuration a host uses: answers on the main dispatch queue,
    /// after the call that asked has returned.
    @MainActor @Test func aGuestAwaitsTheHostsPickers() async throws {
        HostDocuments.deliver = { DispatchQueue.main.async(execute: $0) }
        let picker = self.picker
        let presenter = self.presenter
        let opening = Task { @MainActor in
            try await picker.open([.plainText], access: .readWrite)
        }
        while presenter.picks.isEmpty {
            await Task.yield()
        }
        presenter.picks.removeLast()(.success([HostDocument(path: path("notes.txt"), isWritable: true)]))
        let document = try #require(try await opening.value)
        #expect(document.name == "notes.txt")
        let bookmark = try await document.bookmark()
        #expect(try await Document.resolving(bookmark).name == "notes.txt")

        HostDocuments.presenter = nil
        do {
            _ = try await picker.openFolder()
            Issue.record("there's no picker to show")
        } catch {
            #expect(error == .unsupported)
        }
    }
}
