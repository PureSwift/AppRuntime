import Foundation
import Testing
import DynamicUI
import RuntimeABI
import RuntimeNative
import RuntimeWasm

/// The example notes app as App.wasm under WasmKit: a split view, the
/// window's values and `dismiss`, in an Embedded guest. The test renderer
/// reports a compact window, then a regular one, and goes back as a
/// collapsed split view would. Part of `WasmShimTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleNotes`; skipped without it.
    static var exampleNotesURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleNotes/wasm32/App.wasm")
    }

    func startExampleNotes(window: RenderEnvironment?) throws -> WasmTestRenderer {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        WasmTestRenderer.last = nil
        WasmTestRenderer.window = window
        let bytes = Array(try Data(contentsOf: Self.exampleNotesURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime)
        #expect(try app.start() == .ok)
        return try #require(WasmTestRenderer.last)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleNotesURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleNotes"))
    func exampleNotesInWasmMode() throws {
        defer { WasmTestRenderer.window = nil }
        let renderer = try startExampleNotes(window: RenderEnvironment(horizontalSizeClass: .compact, colorScheme: .light))
        #expect(renderer.applies == 1, "laid out once, for the window it's in")
        func split() throws -> RenderNode {
            try #require(renderer.screen?.first { $0.type == "NavSplit" })
        }
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.first { $0.type == "Text" }?.props["text"]
        }
        func tag(_ row: RenderNode) -> Int? {
            row.modifiers.first { $0.kind == "tag" }?.args["value"]?.int
        }

        var view = try split()
        #expect(view.props["compactColumn"] == "sidebar")
        #expect(view.children.map { $0.props["column"] } == ["sidebar", "content", "detail"])
        #expect(view.children[0].props["title"] == "Folders")
        #expect(view.children[0].props["idealWidth"] == 220.0)

        // The folders are lazy: the host asks for the rows it shows.
        let folders = try #require(view.children[0].first { $0.type == "List" })
        let listID = RenderCodec.encode(id: folders.id)
        #expect(renderer.delegate.rowCount(listID) == 2)
        let work = try RenderCodec.decode(renderer.delegate.row(listID, index: 0))
        #expect(work.type == "Label" && work.props["title"] == "Work")
        let workTag = try #require(tag(work))

        // The user picks Work: its notes show, in the next column.
        renderer.send(folders, .change, .int(workTag))
        view = try split()
        #expect(view.props["compactColumn"] == "content")
        #expect(view.children[1].props["title"] == "Work")
        let notes = try #require(view.children[1].first { $0.type == "List" })
        #expect(notes.children.count == 2)
        #expect(renderer.screen?.identified("note-Plan")?.type == "HStack")
        let plan = try #require(tag(notes.children[0]))

        // And a note: the detail, with what the window is like.
        renderer.send(notes, .change, .int(plan))
        view = try split()
        #expect(view.props["compactColumn"] == "detail")
        #expect(view.children[2].props["title"] == "Plan")
        #expect(text("title") == "Plan")
        #expect(text("width") == "Narrow window")
        #expect(text("scheme") == "Light")

        // The window widens and goes dark; then the text grows.
        renderer.report(RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .dark))
        #expect(text("width") == "Wide window")
        #expect(text("scheme") == "Dark")
        renderer.report(RenderEnvironment(horizontalSizeClass: .regular, colorScheme: .dark, dynamicTypeSize: .accessibility1))
        #expect(renderer.screen?.identified("note-Plan")?.type == "VStack")

        // Back from the note: it's no longer picked.
        renderer.send(try split(), .pop, 2)
        view = try split()
        #expect(view.props["compactColumn"] == "content")
        #expect(view.children[2].first { $0.type == "Text" }?.props["text"] == "Pick a note")
        #expect(view.children[1].first { $0.type == "List" }?.props["selection"] == nil)

        // A note added in a sheet, which dismisses itself.
        renderer.send(try #require(renderer.screen?.button("New Note")), .tap)
        let sheet = try #require(renderer.screen?.first { $0.type == "Sheet" })
        #expect(sheet.props["isPresented"] == true)
        let field = try #require(sheet.first { $0.type == "TextField" })
        renderer.send(field, .change, "Ideas")
        renderer.send(try #require(renderer.screen?.button("Add")), .tap)
        #expect(renderer.screen?.first { $0.type == "Sheet" }?.props["isPresented"] == false)
        view = try split()
        #expect(text("title") == "Ideas")
        #expect(view.children[1].first { $0.type == "List" }?.children.count == 3)

        // Cancel closes it too, and adds nothing.
        renderer.send(try #require(renderer.screen?.button("New Note")), .tap)
        renderer.send(try #require(renderer.screen?.button("Cancel")), .tap)
        #expect(renderer.screen?.first { $0.type == "Sheet" }?.props["isPresented"] == false)
        #expect(try split().children[1].first { $0.type == "List" }?.children.count == 3)
    }

    /// A renderer from before version 2 gets a stack.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleNotesURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleNotes"))
    func exampleNotesOnAnOlderRenderer() throws {
        let renderer = try startExampleNotes(window: nil)
        #expect(renderer.screen?.first { $0.type == "NavSplit" } == nil)
        let stack = try #require(renderer.screen?.first { $0.type == "NavStack" })
        #expect(stack.children.count == 1)
        #expect(stack.children[0].props["title"] == "Folders")

        let folders = try #require(stack.first { $0.type == "List" })
        let home = try RenderCodec.decode(renderer.delegate.row(RenderCodec.encode(id: folders.id), index: 1))
        let tag = try #require(home.modifiers.first { $0.kind == "tag" }?.args["value"]?.int)
        renderer.send(folders, .change, .int(tag))
        let pushed = try #require(renderer.screen?.first { $0.type == "NavStack" })
        #expect(pushed.children.count == 2)
        #expect(pushed.children[1].props["title"] == "Home")

        renderer.send(pushed, .pop, 1)
        #expect(renderer.screen?.first { $0.type == "NavStack" }?.children.count == 1)
    }
}
