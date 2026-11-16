import Foundation
import Testing
import CRuntime
import DynamicFiles
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative

/// `ExampleFiles`'s library with the shared host implementation keeping
/// real files in a temporary directory: the guest's `FileManager`, the
/// `Files` contract and `HostFiles` in an Embedded guest, as a native slice
/// or through wasm2c (see `Package.swift`). The same checks as
/// `RuntimeWasm`'s WasmKit test. Part of `LinkedSliceTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleFiles: Bool {
        #if LINKED_EXAMPLEFILES
        true
        #else
        false
        #endif
    }

    /// Directories for the app under a new temporary directory, with a
    /// bundle that has a welcome text.
    static func exampleFilesDirectories() throws -> (root: URL, directories: [FileDirectory: String]) {
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleFiles-\\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("App/resources")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("Welcome to the notebook.".utf8).write(to: bundle.appendingPathComponent("welcome.txt"))
        return (root, [
            .documents: root.appendingPathComponent("Documents").path,
            .data: root.appendingPathComponent("Data").path,
            .caches: root.appendingPathComponent("Caches").path,
            .temporary: root.appendingPathComponent("tmp").path,
            .bundle: bundle.path,
        ])
    }

    /// Drives the app like a player and checks the files it leaves.
    func checkExampleFiles(_ renderer: TestRenderer, root: URL, asyncExport: Bool) throws {
        func onDisk(_ path: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }
        var screen = try #require(renderer.screen)
        #expect(screen.identified("welcome")?.props["text"] == "Welcome to the notebook.", "read from the bundle")
        #expect(screen.button("Delete Groceries") == nil)

        // Saving writes notes/<title>.txt, making the folder.
        func save(_ title: String, _ text: String) throws {
            let screen = try #require(renderer.screen)
            renderer.send(try #require(screen.identified("title")), .change, .string(title))
            renderer.send(try #require(screen.identified("text")), .change, .string(text))
            renderer.send(try #require(renderer.screen?.button("Save")), .tap)
        }
        try save("Groceries", "Milk, eggs")
        #expect(onDisk("Documents/notes/Groceries.txt") == "Milk, eggs")
        #expect(renderer.screen?.identified("status")?.props["text"] == "Saved Groceries")
        try save("Ideas", "A notebook app")
        screen = try #require(renderer.screen)
        #expect(screen.button("Groceries") != nil && screen.button("Ideas") != nil, "listed from the directory")
        #expect(screen.identified("title")?.props["text"] == "")

        // A title that would leave the folder is refused by the host.
        try save("../../escape", "x")
        #expect(renderer.screen?.identified("status")?.props["text"] == "Couldn\u{27}t save: error 6")
        #expect(onDisk("escape.txt") == nil)

        // Opening reads the file.
        renderer.send(try #require(renderer.screen?.button("Ideas")), .tap)
        #expect(renderer.screen?.identified("opened")?.props["text"] == "A notebook app")

        if asyncExport {
            // The export awaits each read and a write, in a task.
            renderer.send(try #require(renderer.screen?.button("Export")), .tap)
            #expect(onDisk("Caches/exports/all.txt") == "# Groceries\nMilk, eggs\n# Ideas\nA notebook app\n")
            #expect(renderer.screen?.identified("status")?.props["text"] == "Exported 2 notes, 46 bytes")
        }

        // Deleting removes the file, and the list follows.
        renderer.send(try #require(renderer.screen?.button("Delete Groceries")), .tap)
        #expect(onDisk("Documents/notes/Groceries.txt") == nil)
        screen = try #require(renderer.screen)
        #expect(screen.button("Groceries") == nil && screen.button("Ideas") != nil)
        #expect(screen.identified("status")?.props["text"] == "Deleted Groceries")
        #expect(onDisk("Documents/notes/Ideas.txt") == "A notebook app")
    }

    @Test(.enabled(if: linksExampleFiles, "Link ExampleFiles's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleFiles() throws {
        #if LINKED_EXAMPLEFILES
        let (root, directories) = try Self.exampleFilesDirectories()
        defer { try? Foundation.FileManager.default.removeItem(at: root) }
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        // The host does its work at once, so each tap's files are there
        // when the tap returns.
        try HostFiles.configure(HostFiles.Configuration(directories: directories, work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        try checkExampleFiles(try #require(TestRenderer.last), root: root, asyncExport: true)
        #endif
    }
}
