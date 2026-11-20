import Foundation
import Testing
import DynamicDocuments
import DynamicFiles
import DynamicUI
import RuntimeABI
import RuntimeDocuments
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// A host's pickers that answer at once with what the test set, as a user
/// who has already decided would.
final class WasmTestPresenter: DocumentPresenter {

    var calls: [String] = []

    /// What the next open picker gives; nothing is a cancel.
    var picked: [HostDocument] = []

    var folder: HostDocument?

    /// Where the next save goes; `nil` is a cancel.
    var destination: String?

    func pick(types: [String], multiple: Bool, access: DocumentAccess, completion: @escaping (Result<[HostDocument], DocumentError>) -> Void) {
        calls.append("pick \(types) \(multiple) \(access)")
        completion(.success(picked))
    }

    func pickFolder(access: DocumentAccess, completion: @escaping (Result<HostDocument?, DocumentError>) -> Void) {
        calls.append("pickFolder \(access)")
        completion(.success(folder))
    }

    func export(file source: String, name: String, completion: @escaping (Result<HostDocumentExport, DocumentError>) -> Void) {
        calls.append("export \(name)")
        guard let destination else {
            completion(.success(.cancelled))
            return
        }
        do {
            try HostFiles.copy(file: source, to: destination)
            completion(.success(.saved(HostDocument(path: destination, isWritable: true))))
        } catch {
            completion(.failure(.unknown))
        }
    }

    func bookmark(_ document: HostDocument, completion: @escaping (Result<String, DocumentError>) -> Void) {
        completion(.failure(.unsupported))
    }

    func resolve(_ bookmark: String, completion: @escaping (Result<HostDocument, DocumentError>) -> Void) {
        completion(.failure(.unsupported))
    }

    func forget(_ bookmark: String) { }
}

/// The example documents app as App.wasm under WasmKit, with the shared
/// host implementations and real files in a temporary directory: the
/// guest's `DocumentPicker`, `fileImporter` and `FileManager`, the
/// `Documents` contract, and `HostDocuments` granting directories in
/// `HostFiles`, end to end. Part of `WasmShimTests`, which is serialized,
/// since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleDocuments`; skipped without it.
    static var exampleDocumentsURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleDocuments/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleDocumentsURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleDocuments"))
    func exampleDocumentsInWasmMode() throws {
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleDocuments-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        // The user's own files, outside the app's directories.
        let home = root.appendingPathComponent("Home")
        try manager.createDirectory(at: home.appendingPathComponent("Letters"), withIntermediateDirectories: true)
        try Data("Dear reader".utf8).write(to: home.appendingPathComponent("letter.txt"))
        try Data("Opened from the file manager".utf8).write(to: home.appendingPathComponent("launched.txt"))
        try Data("First of May".utf8).write(to: home.appendingPathComponent("Letters/may.txt"))
        func onDisk(_ path: String) -> String? {
            (try? Data(contentsOf: home.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }
        func file(_ name: String) -> String {
            home.appendingPathComponent(name).path
        }

        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        // The hosts do their work at once, so each tap's files are there
        // when the tap returns.
        let container = root.appendingPathComponent("Container")
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let presenter = WasmTestPresenter()
        HostDocuments.reset()
        HostDocuments.presenter = presenter
        HostDocuments.deliver = { $0() }
        HostDocumentsModule.register(in: native)
        defer { HostDocuments.reset() }
        WasmTestRenderer.last = nil

        // The app is launched with a file, before it has started to listen.
        HostDocuments.open([HostDocument(path: file("launched.txt"))])

        let bytes = Array(try Data(contentsOf: Self.exampleDocumentsURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.userFiles])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.documents.Documents" }?.capability == .userFiles)
        #expect(contracts.contains { $0.name == "org.pureswift.documents.Grant" })
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }

        #expect(text("name") == "launched.txt", "what it was opened with waited for it")
        #expect(text("text") == "Opened from the file manager")
        #expect(text("status") == "Opened launched.txt, read-only")
        try tap("Save")
        #expect(text("status") == "Couldn\u{27}t save: error 7", "the host refuses a write to a file given for reading")
        #expect(onDisk("launched.txt") == "Opened from the file manager")

        // The importer shows the picker, and the picked file is read
        // through Files.
        presenter.picked = [HostDocument(path: file("letter.txt"), isWritable: true)]
        try tap("Open")
        #expect(presenter.calls == [#"pick ["text/plain"] false readWrite"#])
        #expect(text("name") == "letter.txt")
        #expect(text("text") == "Dear reader")
        #expect(text("status") == "Opened letter.txt")

        // Saving writes the user's file where it is.
        renderer.send(try #require(renderer.screen?.identified("text")), .change, .string("Dear reader, again"))
        try tap("Save")
        #expect(onDisk("letter.txt") == "Dear reader, again")
        #expect(text("status") == "Saved letter.txt")
        #expect(try manager.contentsOfDirectory(atPath: home.path).sorted() == ["Letters", "launched.txt", "letter.txt"])

        // Cancelling the picker changes nothing, and it can show again.
        presenter.picked = []
        try tap("Open")
        #expect(presenter.calls.count == 2 && text("name") == "letter.txt")

        // A copy goes where the user says, and is the open document from then on.
        presenter.destination = file("Letters/copy.txt")
        try tap("Save a Copy")
        #expect(presenter.calls.last == "export Copy of letter.txt")
        #expect(onDisk("Letters/copy.txt") == "Dear reader, again")
        #expect(text("name") == "copy.txt")
        #expect(text("status") == "Saved as copy.txt")
        renderer.send(try #require(renderer.screen?.identified("text")), .change, .string("A copy, changed"))
        try tap("Save")
        #expect(onDisk("Letters/copy.txt") == "A copy, changed")
        #expect(onDisk("letter.txt") == "Dear reader, again", "the first file is let go, and left alone")
        presenter.destination = nil
        try tap("Save a Copy")
        #expect(text("status") == "Not saved")

        // A folder is a directory: listed, and read by a path under it.
        presenter.folder = HostDocument(path: file("Letters"), kind: .directory)
        try tap("Open Folder")
        #expect(text("status") == "2 in Letters")
        try tap("may.txt")
        #expect(text("text") == "First of May")
        #expect(text("status") == "Read may.txt from Letters")

        // Opened again while it runs.
        HostDocuments.open([HostDocument(path: file("letter.txt"), isWritable: true)])
        #expect(text("name") == "letter.txt")
        #expect(text("status") == "Opened letter.txt")
    }
}
