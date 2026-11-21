import Foundation
import Testing
import CRuntime
import DynamicFiles
import DynamicRuntime
import DynamicText
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimeText

/// A platform whose text views are texts in memory, which the test types
/// into as the user would.
final class LinkedTextPlatform: TextPlatform {

    var engines: [MemoryTextEngine] = []

    let maximumLength = 1 << 20

    func makeEngine(for storage: HostTextStorage) -> any TextEngine {
        let engine = MemoryTextEngine(storage: storage)
        engines.append(engine)
        return engine
    }
}

/// `ExampleText`'s library with the shared host implementation over texts
/// the test keeps in memory: the guest's `TextBuffer`, `TextEditor` and
/// `@FocusState`, the `TextStorage` contract and `HostTextStorage`, in an
/// Embedded guest, as a native slice or through wasm2c (see
/// `Package.swift`). The same checks as `RuntimeWasm`'s WasmKit test. Part
/// of `LinkedSliceTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleText: Bool {
        #if LINKED_EXAMPLETEXT
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleText, "Link ExampleText's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleText() throws {
        #if LINKED_EXAMPLETEXT
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleText-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        // The app's bundle: a text with Windows line endings.
        let resources = root.appendingPathComponent("App/resources")
        let documents = root.appendingPathComponent("Container/Documents")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("Welcome\r\nThis is the first note.\r\nEdit me.\r\n".utf8).write(to: resources.appendingPathComponent("welcome.txt"))

        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .bundle: resources.path,
            .documents: documents.path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let platform = LinkedTextPlatform()
        HostTextStorage.reset()
        HostTextStorage.platform = platform
        HostTextStorage.work = { $0() }
        HostTextStorage.deliver = { $0() }
        HostTextModule.register(in: native)
        defer { HostTextStorage.reset() }
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func editors() -> [RenderNode] {
            var found: [RenderNode] = []
            func visit(_ node: RenderNode) {
                if node.type == "TextEditor" { found.append(node) }
                node.children.forEach(visit)
            }
            if let screen = renderer.screen { visit(screen) }
            return found
        }
        func contents(_ engine: MemoryTextEngine) -> String {
            engine.text(in: 0 ..< engine.length)
        }

        // The app loaded its text from the bundle into a text of the host's.
        var expected = "Welcome\nThis is the first note.\nEdit me.\n"
        let main = try #require(platform.engines.first)
        #expect(contents(main) == expected, "with `\\n` only")
        #expect(text("status") == "Opened welcome.txt" && text("title") == "welcome.txt")
        #expect(text("format") == .string("\(expected.utf16.count) units, 4 lines, utf-8, CRLF, 1 edits"), "what the file was")
        #expect(text("position") == "Line 1, column 1")

        // The node says which text it shows, and how.
        let shown = editors()
        #expect(shown.count == 2 && platform.engines.count == 2, "the note's editor keeps a buffer of its own")
        guard case .int(let identifier)? = shown[0].props["buffer"] else {
            Issue.record("the node names its text")
            return
        }
        #expect(HostTextStorage.storage(for: Int32(identifier))?.engine === main)
        #expect(shown[0].props["editable"] == true && shown[0].props["wraps"] == true)
        func modifier(_ kind: String) -> [String: PropValue]? {
            editors().first?.modifiers.first { $0.kind == kind }?.args
        }
        #expect(modifier("font")?["design"] == "monospaced")
        #expect(modifier("autocorrection") == ["disabled": true] && modifier("autocapitalization") == ["mode": "never"])
        #expect(modifier("focused") == ["value": false])

        // The user moves the caret and types. Nothing of it crosses to the
        // guest but that it happened.
        main.selection = 8 ..< 8
        #expect(text("position") == "Line 2, column 1")
        main.type("> ")
        expected = "Welcome\n> This is the first note.\nEdit me.\n"
        #expect(text("title") == "welcome.txt, edited" && text("position") == "Line 2, column 3")
        #expect(text("format") == .string("\(expected.utf16.count) units, 4 lines, utf-8, CRLF, 2 edits"))

        // The app undoes the user's typing, and redoes it.
        try tap("Undo")
        #expect(contents(main) == "Welcome\nThis is the first note.\nEdit me.\n" && text("position") == "Line 2, column 1")
        #expect(text("title") == "welcome.txt, edited", "undoing doesn't make it saved")
        try tap("Redo")
        #expect(contents(main) == expected)

        // Finding is the host's: the guest doesn't hold the text.
        renderer.send(try #require(renderer.screen?.identified("query")), .change, "NOTE")
        try tap("Find Next")
        let match = try #require(expected.range(of: "note"))
        let found = match.lowerBound.utf16Offset(in: expected) ..< match.upperBound.utf16Offset(in: expected)
        #expect(text("status") == .string("Found at \(found.lowerBound)"))
        #expect(main.selection == found && main.revealed == found)
        #expect(text("position") == .string("Line 2, column \(found.lowerBound - 8 + 1), 4 selected"))
        try tap("Find Next")
        #expect(main.selection == found, "round to the only match again")

        // Replacing every match is one undo step.
        renderer.send(try #require(renderer.screen?.identified("query")), .change, "me")
        renderer.send(try #require(renderer.screen?.identified("replacement")), .change, "it")
        try tap("Replace All")
        expected = "Welcoit\n> This is the first note.\nEdit it.\n"
        #expect(text("status") == "Replaced 2" && contents(main) == expected)
        try tap("Undo")
        #expect(contents(main) == "Welcome\n> This is the first note.\nEdit me.\n")
        try tap("Redo")

        // An edit of the app's own goes where the caret is.
        main.selection = main.length ..< main.length
        try tap("Rule")
        expected += "\n----\n"
        #expect(contents(main) == expected && main.selection == main.length ..< main.length)

        // Saving writes the file as it was found: with Windows line endings.
        try tap("Save")
        #expect(text("status") == "Saved" && text("title") == "welcome.txt")
        let saved = try Data(contentsOf: documents.appendingPathComponent("edited.txt"))
        #expect(String(decoding: saved, as: UTF8.self) == "Welcoit\r\n> This is the first note.\r\nEdit it.\r\n\r\n----\r\n")
        main.type("more")
        #expect(text("title") == "welcome.txt, edited")

        // Focus is state: the app gives the editor the keyboard, and
        // hears when the user takes it away.
        try tap("Edit")
        #expect(modifier("focused") == ["value": true] && renderer.screen?.button("Done") != nil)
        renderer.send(try #require(editors().first), .focus, false)
        #expect(modifier("focused") == ["value": false] && renderer.screen?.button("Edit") != nil)
        renderer.send(try #require(editors().first), .focus, true)
        #expect(renderer.screen?.button("Done") != nil)

        // The note is edited through a binding: the whole text, each time.
        let note = try #require(platform.engines.last)
        #expect(contents(note) == "Remember" && text("note") == "Note: Remember")
        note.selection = 8 ..< 8
        note.type(" the milk")
        #expect(text("note") == "Note: Remember the milk")
        #expect(platform.engines.count == 2 && editors().count == 2)
        #endif
    }
}
