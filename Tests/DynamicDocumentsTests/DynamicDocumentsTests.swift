import Testing
import DynamicDocuments
import DynamicFiles
import DynamicRuntime
import DynamicSwiftUI
import DynamicUI
import RuntimeNative

/// A grant the test's host hands out, which says when the guest let go.
final class ScriptedGrant: DocumentGrant {

    nonisolated(unsafe) static var released: [Int32] = []

    let directoryValue: Int32
    let nameValue: String
    let kindValue: Int32
    let type: String?
    let writable: Bool

    var bookmarks: [any DocumentCallback] = []

    init(_ directory: Int32, _ name: String, kind: Int32 = 0, type: String? = nil, writable: Bool = false) {
        self.directoryValue = directory
        self.nameValue = name
        self.kindValue = kind
        self.type = type
        self.writable = writable
    }

    deinit {
        Self.released.append(directoryValue)
    }

    func directory() -> Int32 { directoryValue }
    func name() -> String { nameValue }
    func kind() -> Int32 { kindValue }
    func contentType() -> String? { type }
    func isWritable() -> Bool { writable }

    func bookmark(_ callback: any DocumentCallback) {
        bookmarks.append(callback)
    }
}

/// A host's documents that only write down what they're asked, and keep
/// each callback for the test to answer.
final class ScriptedDocuments: Documents {

    nonisolated(unsafe) static var instance = ScriptedDocuments()

    var calls: [String] = []

    var callbacks: [any DocumentCallback] = []

    var delegate: (any DocumentsDelegate)?

    static func shared() -> ScriptedDocuments { instance }

    /// The callback of the operation issued `back` operations ago.
    func callback(_ back: Int = 0) -> any DocumentCallback {
        callbacks[callbacks.count - 1 - back]
    }

    func pick(_ types: [String], multiple: Bool, access: Int32, callback: any DocumentCallback) {
        calls.append("pick \(types) \(multiple) \(access)")
        callbacks.append(callback)
    }

    func pickPhotos(_ kinds: Int32, multiple: Bool, callback: any DocumentCallback) {
        calls.append("pickPhotos \(kinds) \(multiple)")
        callbacks.append(callback)
    }

    func pickFolder(_ access: Int32, callback: any DocumentCallback) {
        calls.append("pickFolder \(access)")
        callbacks.append(callback)
    }

    func export(_ directory: Int32, path: String, name: String, callback: any DocumentCallback) {
        calls.append("export \(directory) \(path) \(name)")
        callbacks.append(callback)
    }

    func resolve(_ bookmark: String, callback: any DocumentCallback) {
        calls.append("resolve \(bookmark)")
        callbacks.append(callback)
    }

    func forget(_ bookmark: String) {
        calls.append("forget \(bookmark)")
    }

    func setDelegate(_ delegate: (any DocumentsDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }
}

/// A host's documents with no photo picker: it implements everything but
/// `pickPhotos`, and gets the default.
final class FilesOnlyDocuments: Documents {

    var calls: [String] = []

    static func shared() -> FilesOnlyDocuments { FilesOnlyDocuments() }

    func pick(_ types: [String], multiple: Bool, access: Int32, callback: any DocumentCallback) {
        calls.append("pick \(types) \(multiple) \(access)")
    }

    func pickFolder(_ access: Int32, callback: any DocumentCallback) { }
    func export(_ directory: Int32, path: String, name: String, callback: any DocumentCallback) { }
    func resolve(_ bookmark: String, callback: any DocumentCallback) { }
    func forget(_ bookmark: String) { }
    func setDelegate(_ delegate: (any DocumentsDelegate)?) { }
}

/// A callback nothing answers.
final class UnheardCallback: DocumentCallback {
    func didPick(_ documents: [any DocumentGrant]) { }
    func didComplete() { }
    func didBookmark(_ bookmark: String) { }
    func didFail(_ error: Int32) { }
}

/// Records what a view graph sends.
final class DocumentSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

/// What a screen with both pickers keeps.
@Observable final class Desk {
    var importing = false
    var exporting = false
    var draft: FilePath? = .temporary / "Untitled.txt"
    var imported: [String] = []
    var saved: [String?] = []
    var failures: [DocumentError] = []
}

struct DeskView: View {

    let desk: Desk

    var body: some View {
        Text("Desk")
            .fileImporter(
                isPresented: Binding(get: { desk.importing }, set: { desk.importing = $0 }),
                allowedContentTypes: [UTType.png, .jpeg],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let documents): desk.imported += documents.map(\.name)
                case .failure(let error): desk.failures.append(error)
                }
            }
            .fileExporter(
                isPresented: Binding(get: { desk.exporting }, set: { desk.exporting = $0 }),
                file: desk.draft,
                defaultFilename: "Notes.txt"
            ) { result in
                switch result {
                case .success(let document): desk.saved.append(document?.name)
                case .failure(let error): desk.failures.append(error)
                }
            }
    }
}

/// Serialized: the tests share the native runtime and the scripted host,
/// and the frontend keeps the graph being evaluated in a global.
@Suite(.serialized) struct DynamicDocumentsTests {

    let host: ScriptedDocuments

    let picker: DocumentPicker

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        DocumentsProxy.register(ScriptedDocuments.self, in: native)
        DocumentGrantProxy.register(ScriptedGrant.self, in: native)
        DocumentCallbackProxy.registerInterface(in: native)
        DocumentsDelegateProxy.registerInterface(in: native)
        host = ScriptedDocuments()
        ScriptedDocuments.instance = host
        ScriptedGrant.released = []
        DocumentPicker.onOpen(nil)
        host.calls = []
        picker = DocumentPicker()
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    // MARK: Contracts

    @Test func pickersRequireUserFiles() {
        let documents = DocumentsProxy.descriptor
        #expect(documents.name == "org.pureswift.documents.Documents")
        #expect(documents.capability == .userFiles)
        #expect(method(documents, "shared")?.kind == .constructor)
        #expect(method(documents, "pick:multiple:access:callback:")?.signature == Signature("(OZIO)V"))
        #expect(method(documents, "pickFolder:callback:")?.signature == Signature("(IO)V"))
        #expect(method(documents, "pickPhotos:multiple:callback:")?.signature == Signature("(IZO)V"))
        #expect(documents.version == 1)
        #expect(method(documents, "export:path:name:callback:")?.signature == Signature("(IOOO)V"))
        #expect(method(documents, "resolve:callback:")?.signature == Signature("(OO)V"))
        #expect(method(documents, "forget:")?.signature == Signature("(O)V"))
        #expect(method(documents, "setDelegate:")?.signature == Signature("(O)V"))
        #expect(documents.methods.count == 8)
    }

    @Test func aGrantSaysWhichDirectoryItIs() {
        let grant = DocumentGrantProxy.descriptor
        #expect(grant.name == "org.pureswift.documents.Grant")
        #expect(grant.capability == nil, "it's only had from a picker")
        #expect(method(grant, "directory")?.signature == Signature("()I"))
        #expect(method(grant, "name")?.signature == Signature("()O"))
        #expect(method(grant, "kind")?.signature == Signature("()I"))
        #expect(method(grant, "contentType")?.signature == Signature("()O"))
        #expect(method(grant, "isWritable")?.signature == Signature("()Z"))
        #expect(method(grant, "bookmark:")?.signature == Signature("(O)V"))
        #expect(grant.methods.count == 6)
    }

    @Test func callbacksCarryOneAnswer() {
        let callback = DocumentCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.documents.Callback")
        #expect(callback.kind == .callback)
        #expect(method(callback, "didPick:")?.signature == Signature("(O)V"))
        #expect(method(callback, "didComplete")?.signature == Signature("()V"))
        #expect(method(callback, "didBookmark:")?.signature == Signature("(O)V"))
        #expect(method(callback, "didFail:")?.signature == Signature("(I)V"))
        let delegate = DocumentsDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.documents.Delegate")
        #expect(method(delegate, "didOpen:")?.signature == Signature("(O)V"))
        let descriptors = [DocumentsProxy.descriptor, DocumentGrantProxy.descriptor, callback, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Content types

    @Test func contentTypesAreMIMETypesAndExtensions() {
        #expect(ContentType.png.mimeType == "image/png")
        #expect(ContentType.jpeg.fileExtensions == ["jpg", "jpeg"])
        #expect(ContentType.jpeg.preferredFilenameExtension == "jpg")
        #expect(ContentType(mimeType: "IMAGE/PNG") == .png)
        #expect(ContentType(mimeType: "application/x-thing") == ContentType(mimeType: "application/x-thing", fileExtensions: []))
        #expect(ContentType(filenameExtension: ".JPEG") == .jpeg)
        #expect(ContentType(filenameExtension: "ics") == .calendarEvent)
        #expect(ContentType(filenameExtension: "nothing") == nil)
        #expect(ContentType(filenameExtension: "") == nil)
        #expect(UTType.pdf == ContentType.pdf, "SwiftUI's name for it")
    }

    @Test func aTypeConformsToItsGroup() {
        #expect(ContentType.png.conforms(to: .image))
        #expect(ContentType.png.conforms(to: .png))
        #expect(ContentType.png.conforms(to: .item))
        #expect(!ContentType.png.conforms(to: .audio))
        #expect(!ContentType.image.conforms(to: .png))
        #expect(ContentType.mpeg4Movie.conforms(to: .movie))
        #expect(ContentType.image.isGroup && !ContentType.png.isGroup)
    }

    @Test func aPickerIsAskedInTheWiresForms() {
        let gpx = ContentType(fileExtensions: ["gpx", "trk"])
        picker.open([.image, .pdf, gpx, .pdf], allowsMultiple: true) { _ in }
        #expect(host.calls == [#"pick ["image/*", "application/pdf", ".gpx", ".trk"] true 0"#])
        picker.open(allowsMultiple: false, access: .readWrite) { (_: Result<[Document], DocumentError>) in }
        #expect(host.calls.last == "pick [] false 1")
        picker.open([.png, .item]) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pick [] false 0", "anything is no type in particular")
    }

    // MARK: The photo picker

    @Test func aPhotoPickerIsAskedForImagesVideosOrBoth() throws {
        picker.open([.image], from: .photoLibrary) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls == ["pickPhotos 1 false"])
        picker.open([.movie], from: .photoLibrary, allowsMultiple: true) { _ in }
        #expect(host.calls.last == "pickPhotos 2 true")
        picker.open(from: .photoLibrary) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pickPhotos 3 false", "no type in particular is both")
        picker.open([.png, .quickTimeMovie], from: .photoLibrary) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pickPhotos 3 false")
        picker.open([.heic, .jpeg], from: .photoLibrary) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pickPhotos 1 false")
        // Types a photo library has none of ask for what it has.
        picker.open([.pdf, .item], from: .photoLibrary) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pickPhotos 3 false")
        // Photos are read: the access asked for isn't sent.
        picker.open([.image], from: .photoLibrary, access: .readWrite) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == "pickPhotos 1 false")
        #expect(!host.calls.contains { $0.hasPrefix("pick ") }, "the document picker never showed")

        // The files, as before, when nothing says otherwise.
        picker.open([.image], from: .files) { (_: Result<Document?, DocumentError>) in }
        #expect(host.calls.last == #"pick ["image/*"] false 0"#)
    }

    @Test func aPickedPhotoIsADocument() throws {
        var result: Result<[Document], DocumentError>?
        picker.open([.image, .movie], from: .photoLibrary, allowsMultiple: true) { result = $0 }
        host.callback().didPick([
            ScriptedGrant(310, "IMG_0042.HEIC", type: "image/heic"),
            ScriptedGrant(311, "IMG_0043.MOV", type: "video/quicktime"),
        ])
        let picked = try #require(try result?.get())
        #expect(picked.map(\.name) == ["IMG_0042.HEIC", "IMG_0043.MOV"])
        #expect(picked.map(\.contentType) == [.heic, .quickTimeMovie])
        #expect(picked.allSatisfy { !$0.isWritable && $0.path.directory.isGrant })

        var cancelled: Result<Document?, DocumentError>?
        picker.open([.image], from: .photoLibrary) { cancelled = $0 }
        host.callback().didPick([])
        #expect(try cancelled?.get() == nil && cancelled != nil, "cancelling isn't an error")
    }

    @Test func aHostWithNoPhotoPickerShowsItsDocumentPicker() {
        // What a host that implements the contract itself gets, until it
        // has a photo picker of its own.
        let old = FilesOnlyDocuments()
        old.pickPhotos(1, multiple: true, callback: UnheardCallback())
        old.pickPhotos(2, multiple: false, callback: UnheardCallback())
        old.pickPhotos(3, multiple: false, callback: UnheardCallback())
        #expect(old.calls == [#"pick ["image/*"] true 0"#, #"pick ["video/*"] false 0"#, #"pick ["image/*", "video/*"] false 0"#])
        // Neither bit, or bits from a newer guest alone, is both.
        old.pickPhotos(0, multiple: false, callback: UnheardCallback())
        old.pickPhotos(8, multiple: false, callback: UnheardCallback())
        #expect(old.calls.suffix(2) == [#"pick ["image/*", "video/*"] false 0"#, #"pick ["image/*", "video/*"] false 0"#])
    }

    // MARK: Opening

    @Test func aPickedFileIsADocument() throws {
        var result: Result<Document?, DocumentError>?
        picker.open([.image]) { result = $0 }
        #expect(result == nil, "nothing until the host answers")
        host.callback().didPick([ScriptedGrant(300, "IMG_0042.jpg", type: "image/jpeg", writable: true)])
        let photo = try #require(try result?.get())
        #expect(photo.name == "IMG_0042.jpg")
        #expect(photo.kind == .file && !photo.isDirectory)
        #expect(photo.contentType == .jpeg)
        #expect(photo.isWritable)
        #expect(photo.path == FilePath(FileDirectory(rawValue: 300)))
        #expect(photo.path.directory.isGrant && photo.path.path.isEmpty)
    }

    @Test func aDocumentsTypeComesFromItsNameWhenTheHostHasNone() throws {
        var result: Result<[Document], DocumentError>?
        picker.open(allowsMultiple: true) { result = $0 }
        host.callback().didPick([
            ScriptedGrant(300, "notes.TXT"),
            ScriptedGrant(301, "Makefile"),
            ScriptedGrant(302, ".hidden"),
            ScriptedGrant(303, "Music", kind: 1),
            ScriptedGrant(304, "track", type: "audio/x-unheard-of"),
            ScriptedGrant(305, "odd.", kind: 9),
        ])
        let documents = try #require(try result?.get())
        #expect(documents.map(\.name) == ["notes.TXT", "Makefile", ".hidden", "Music", "track", "odd."])
        #expect(documents[0].contentType == .plainText)
        #expect(documents[1].contentType == nil && documents[2].contentType == nil && documents[5].contentType == nil)
        #expect(documents[3].contentType == .folder && documents[3].isDirectory)
        #expect(documents[4].contentType?.mimeType == "audio/x-unheard-of")
        #expect(documents[5].kind == .file, "a kind from a newer host isn't a folder")
        #expect(!documents[0].isWritable)
    }

    @Test func cancellingIsNoDocuments() throws {
        var one: Result<Document?, DocumentError>?
        picker.open([.image]) { one = $0 }
        host.callback().didPick([])
        #expect(try one?.get() == nil && one != nil)

        var many: Result<[Document], DocumentError>?
        picker.open(allowsMultiple: true) { many = $0 }
        host.callback().didPick([])
        #expect(try many?.get().isEmpty == true)

        var folder: Result<Document?, DocumentError>?
        picker.openFolder { folder = $0 }
        #expect(host.calls.last == "pickFolder 0")
        host.callback().didPick([])
        #expect(try folder?.get() == nil && folder != nil)
    }

    @Test func aFoldersFilesAreUnderItsPath() throws {
        var result: Result<Document?, DocumentError>?
        picker.openFolder(access: .readWrite) { result = $0 }
        #expect(host.calls.last == "pickFolder 1")
        host.callback().didPick([ScriptedGrant(310, "Music", kind: 1, writable: true)])
        let library = try #require(try result?.get())
        #expect(library.isDirectory)
        #expect(library.path / "Albums/one.mp3" == FilePath(FileDirectory(rawValue: 310), "Albums/one.mp3"))
    }

    @Test func failuresAreDocumentErrors() {
        var result: Result<[Document], DocumentError>?
        func failure() -> DocumentError? {
            if case .failure(let error) = result { return error }
            return nil
        }
        for (code, error) in [(2, DocumentError.busy), (3, .notAllowed), (4, .unsupported), (7, .limitReached), (99, .unknown)] {
            picker.open(allowsMultiple: true) { result = $0 }
            host.callback().didFail(Int32(code))
            #expect(failure() == error)
        }
        // An answer of the wrong kind is a failure, and only the first counts.
        picker.open(allowsMultiple: true) { result = $0 }
        host.callback().didBookmark("b")
        host.callback().didPick([ScriptedGrant(1, "late")])
        #expect(failure() == .unknown)
    }

    @Test func lettingGoOfADocumentReleasesTheHostsGrant() throws {
        var result: Result<Document?, DocumentError>?
        picker.open { result = $0 }
        host.callback().didPick([ScriptedGrant(320, "a.txt")])
        var document = try result?.get()
        result = nil
        #expect(document != nil)
        #expect(ScriptedGrant.released.isEmpty, "held while the guest holds the document")
        document = nil
        #expect(ScriptedGrant.released == [320])
    }

    // MARK: Saving

    @Test func anExportIsSavedCopiedOrCancelled() throws {
        var result: Result<DocumentExport, DocumentError>?
        picker.export(.temporary / "drafts/Untitled.txt", suggestedName: "Notes.txt") { result = $0 }
        #expect(host.calls == ["export 3 drafts/Untitled.txt Notes.txt"])
        host.callback().didPick([ScriptedGrant(330, "Notes.txt", writable: true)])
        let saved = try #require(try result?.get().document)
        #expect(saved.name == "Notes.txt" && saved.isWritable)

        picker.export(.documents / "report.pdf") { result = $0 }
        #expect(host.calls.last == "export 0 report.pdf report.pdf", "its own name, unless another is suggested")
        host.callback().didComplete()
        guard case .success(.savedCopy) = result else {
            Issue.record("saved, with nothing to reach it by")
            return
        }
        #expect(try result?.get().document == nil)

        picker.export(saved.path, suggestedName: "Copy.txt") { result = $0 }
        #expect(host.calls.last == "export 330  Copy.txt", "another document can be the source")
        host.callback().didPick([])
        guard case .success(.cancelled) = result else {
            Issue.record("cancelled")
            return
        }

        picker.export(.documents / "none") { result = $0 }
        host.callback().didFail(DocumentError.notFound.rawValue)
        guard case .failure(.notFound) = result else {
            Issue.record("the source is gone")
            return
        }
    }

    // MARK: Bookmarks

    @Test func bookmarksAreStringsTheHostKeeps() throws {
        let grant = ScriptedGrant(340, "a.txt")
        var picked: Result<Document?, DocumentError>?
        picker.open { picked = $0 }
        host.callback().didPick([grant])
        let document = try #require(try picked?.get())

        var bookmark: Result<DocumentBookmark, DocumentError>?
        document.bookmark { bookmark = $0 }
        grant.bookmarks[0].didBookmark("token-1")
        #expect(bookmark == .success(DocumentBookmark(rawValue: "token-1")))

        document.bookmark { bookmark = $0 }
        grant.bookmarks[1].didFail(DocumentError.limitReached.rawValue)
        #expect(bookmark == .failure(.limitReached))

        var resolved: Result<Document, DocumentError>?
        Document.resolve(DocumentBookmark(rawValue: "token-1")) { resolved = $0 }
        #expect(host.calls.last == "resolve token-1")
        host.callback().didPick([ScriptedGrant(341, "a.txt")])
        #expect(try resolved?.get().path.directory.rawValue == 341, "a new grant, with a directory of its own")

        Document.resolve(DocumentBookmark(rawValue: "gone")) { resolved = $0 }
        host.callback().didFail(DocumentError.notPermitted.rawValue)
        #expect(throws: DocumentError.notPermitted) { try resolved?.get() }
        Document.resolve(DocumentBookmark(rawValue: "empty")) { resolved = $0 }
        host.callback().didPick([])
        #expect(throws: DocumentError.notFound) { try resolved?.get() }

        DocumentBookmark(rawValue: "token-1").forget()
        #expect(host.calls.last == "forget token-1")
    }

    // MARK: Opened with a document

    @Test func openedDocumentsReachTheHandler() {
        var opened: [[String]] = []
        DocumentPicker.onOpen { opened.append($0.map(\.name)) }
        #expect(host.calls == ["setDelegate"])
        host.delegate?.didOpen([ScriptedGrant(350, "a.png"), ScriptedGrant(351, "b.png")])
        host.delegate?.didOpen([ScriptedGrant(352, "c.png")])
        #expect(opened == [["a.png", "b.png"], ["c.png"]])
        #expect(ScriptedGrant.released == [350, 351, 352], "what the handler doesn't keep is let go")

        DocumentPicker.onOpen(nil)
        #expect(host.calls == ["setDelegate", "setDelegate nil"], "the host keeps what arrives from here")
        #expect(host.delegate == nil)
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded (§6.4), and so is the native runtime.

    @MainActor @Test func openedDocumentsAreAStream() async {
        let host = self.host
        let reading = Task { @MainActor in
            var names: [String] = []
            for await documents in DocumentPicker.opened {
                names += documents.map(\.name)
                if names.count == 3 { break }
            }
            return names
        }
        while host.delegate == nil {
            await Task.yield()
        }
        host.delegate?.didOpen([ScriptedGrant(360, "a.png"), ScriptedGrant(361, "b.png")])
        host.delegate?.didOpen([ScriptedGrant(362, "c.png")])
        #expect(await reading.value == ["a.png", "b.png", "c.png"])
        #expect(host.calls.last == "setDelegate nil", "a stream that's finished with stops listening")
    }

    @MainActor @Test func pickersCanBeAwaited() async throws {
        let host = self.host
        let picker = self.picker
        let opening = Task { @MainActor in
            try await picker.open([.plainText], access: .readWrite)
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        #expect(host.calls == [#"pick ["text/plain"] false 1"#])
        let grant = ScriptedGrant(370, "todo.txt", writable: true)
        host.callback().didPick([grant])
        let document = try #require(try await opening.value)
        #expect(document.name == "todo.txt")

        let bookmarking = Task { @MainActor in
            try await document.bookmark()
        }
        while grant.bookmarks.isEmpty {
            await Task.yield()
        }
        grant.bookmarks[0].didBookmark("token-2")
        #expect(try await bookmarking.value.rawValue == "token-2")

        let resolving = Task { @MainActor in
            try await Document.resolving(DocumentBookmark(rawValue: "token-2"))
        }
        while host.callbacks.count < 2 {
            await Task.yield()
        }
        host.callback().didPick([ScriptedGrant(371, "todo.txt")])
        #expect(try await resolving.value.path.directory.rawValue == 371)

        let exporting = Task { @MainActor in
            try await picker.export(.temporary / "a.txt")
        }
        while host.callbacks.count < 3 {
            await Task.yield()
        }
        host.callback().didComplete()
        guard case .savedCopy = try await exporting.value else {
            Issue.record("saved a copy")
            return
        }

        let folder = Task { @MainActor in
            try await picker.openFolder()
        }
        while host.callbacks.count < 4 {
            await Task.yield()
        }
        host.callback().didFail(DocumentError.unsupported.rawValue)
        var failure: DocumentError?
        do {
            _ = try await folder.value
        } catch {
            failure = error as? DocumentError
        }
        #expect(failure == .unsupported)
    }

    @MainActor @Test func aCancelledTaskStopsWaiting() async {
        let host = self.host
        let picker = self.picker
        let task = Task { @MainActor in
            try await picker.open([.image], allowsMultiple: true)
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        task.cancel()
        var failure: DocumentError?
        do {
            _ = try await task.value
        } catch {
            failure = error as? DocumentError
        }
        #expect(failure == .cancelled)
        // The picker was still up; what the user picks then is let go.
        host.callback().didPick([ScriptedGrant(380, "late.png")])
        #expect(ScriptedGrant.released == [380])
    }

    // MARK: SwiftUI

    @Test func theImporterShowsThePickerWhilePresented() throws {
        let desk = Desk()
        let sink = DocumentSink()
        let graph = ViewGraph(DeskView(desk: desk), sink: sink)
        graph.update()
        #expect(sink.screen?.type == "Text", "the pickers add nothing to the tree")
        #expect(host.calls.isEmpty)

        desk.importing = true
        graph.update()
        #expect(host.calls == [#"pick ["image/png", "image/jpeg"] true 0"#])
        graph.update()
        #expect(host.calls.count == 1, "one picker, however often the view updates")

        host.callback().didPick([ScriptedGrant(390, "a.png"), ScriptedGrant(391, "b.jpg")])
        #expect(desk.imported == ["a.png", "b.jpg"])
        #expect(!desk.importing, "the picker has gone")

        // Cancelling reports nothing, and a failure does.
        desk.importing = true
        graph.update()
        host.callback().didPick([])
        #expect(!desk.importing && desk.imported.count == 2 && desk.failures.isEmpty)
        desk.importing = true
        graph.update()
        host.callback().didFail(DocumentError.notAllowed.rawValue)
        #expect(!desk.importing && desk.failures == [.notAllowed])
        #expect(host.calls.count == 3)
    }

    @Test func theExporterSavesItsFile() throws {
        let desk = Desk()
        let sink = DocumentSink()
        let graph = ViewGraph(DeskView(desk: desk), sink: sink)
        graph.update()

        desk.exporting = true
        graph.update()
        #expect(host.calls == ["export 3 Untitled.txt Notes.txt"])
        host.callback().didPick([ScriptedGrant(395, "Notes.txt", writable: true)])
        #expect(desk.saved == ["Notes.txt"] && !desk.exporting)

        desk.exporting = true
        graph.update()
        host.callback().didComplete()
        #expect(desk.saved == ["Notes.txt", nil], "a copy the app can't reach")

        desk.exporting = true
        graph.update()
        host.callback().didPick([])
        #expect(desk.saved.count == 2 && !desk.exporting, "cancelling reports nothing")

        // With nothing to save, no picker shows.
        desk.draft = nil
        desk.exporting = true
        graph.update()
        #expect(host.calls.count == 3)
    }
}
