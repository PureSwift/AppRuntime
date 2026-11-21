import Foundation
import Testing
import DynamicFiles
import DynamicRuntime
@testable import DynamicSwiftUI
import DynamicText
import DynamicUI
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeText

/// A platform whose text views are texts in memory, which the test types
/// into. It opens short texts only, and has one encoding of its own.
final class TestTextPlatform: TextPlatform {

    var engines: [MemoryTextEngine] = []

    var maximumLength = 1000

    func makeEngine(for storage: HostTextStorage) -> any TextEngine {
        let engine = MemoryTextEngine(storage: storage)
        engines.append(engine)
        return engine
    }

    func supportsEncoding(_ name: String) -> Bool {
        name == "x-rot13"
    }

    var extraEncodings: TextCoding.Extra? {
        TextCoding.Extra(
            decode: { bytes, _ in bytes.contains { $0 >= 0x80 } ? nil : String(decoding: bytes.map(Self.rotate), as: UTF8.self) },
            encode: { text, _ in text.utf8.contains { $0 >= 0x80 } ? nil : text.utf8.map(Self.rotate) }
        )
    }

    static func rotate(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x41...0x5A: 0x41 + (byte - 0x41 + 13) % 26
        case 0x61...0x7A: 0x61 + (byte - 0x61 + 13) % 26
        default: byte
        }
    }
}

/// File work the test runs when it chooses.
final class HeldWork: @unchecked Sendable {

    var jobs: [@Sendable () -> Void] = []

    func runAll() {
        let waiting = jobs
        jobs = []
        for job in waiting { job() }
    }
}

final class TextSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }

    func modifier(_ kind: String) -> ModifierNode? {
        modifiers.first { $0.kind == kind }
    }
}

struct Editor: View {

    let buffer: TextBuffer

    var body: some View {
        VStack {
            TextEditor(buffer, isEditable: false, wrapsLines: false)
            Text(buffer.isModified ? "Edited" : "Saved")
            Text("\(buffer.length)")
        }
    }
}

/// What a composer edits. Plain: the test says when the view should look
/// again.
final class Draft {
    var message: String = "Hello"
    var selection: TextSelection? = nil
}

struct Composer: View {

    let draft: Draft

    var body: some View {
        TextEditor(text: Binding(get: { draft.message }, set: { draft.message = $0 }))
    }
}

struct SelectingComposer: View {

    let draft: Draft

    var body: some View {
        TextEditor(
            text: Binding(get: { draft.message }, set: { draft.message = $0 }),
            selection: Binding(get: { draft.selection }, set: { draft.selection = $0 })
        )
    }
}

/// `HostTextStorage` over texts in memory and real files, driven from the
/// guest's `TextBuffer` and `TextEditor` through the runtime.
///
/// Serialized: `HostTextStorage`, `HostFiles` and the native runtime are
/// shared, and the frontend keeps the graph being evaluated in a global.
@Suite(.serialized) final class RuntimeTextTests {

    let platform = TestTextPlatform()

    let root: URL

    init() throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("RuntimeTextTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try manager.createDirectory(at: root.appendingPathComponent("Container/Documents"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Home"), withIntermediateDirectories: true)

        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Container/Documents").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostTextStorage.reset()
        HostTextStorage.platform = platform
        HostTextStorage.work = { $0() }
        HostTextStorage.deliver = { $0() }
        HostTextModule.register(in: native)
    }

    deinit {
        HostTextStorage.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func write(_ bytes: [UInt8], _ name: String) throws {
        try Data(bytes).write(to: root.appendingPathComponent("Container/Documents/\(name)"))
    }

    func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: root.appendingPathComponent("Container/Documents/\(name)")))
    }

    /// A buffer with a text, and the engine the host made for it.
    func made(_ text: String) throws -> (TextBuffer, MemoryTextEngine) {
        let buffer = TextBuffer(text)
        _ = buffer.identifier
        return (buffer, try #require(platform.engines.last))
    }

    func load(_ buffer: TextBuffer, _ name: String, encoding: TextEncoding? = nil) -> Result<Void, TextError>? {
        var result: Result<Void, TextError>?
        buffer.load(.documents / name, encoding: encoding) { result = $0 }
        return result
    }

    func save(_ buffer: TextBuffer, _ name: String) -> Result<Void, TextError>? {
        var result: Result<Void, TextError>?
        buffer.save(to: .documents / name) { result = $0 }
        return result
    }

    func failure(_ result: Result<Void, TextError>?) -> TextError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func succeeded(_ result: Result<Void, TextError>?) -> Bool {
        if case .success? = result { return true }
        return false
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostTextModule.contracts.map(\.name) == [
            "org.pureswift.text.Storage", "org.pureswift.text.StorageDelegate", "org.pureswift.text.Callback",
        ])
        #expect(HostTextModule.permissionProviders().isEmpty, "a text needs no capability")
        #expect(TextBuffer.maximumLength == 1000)
        for encoding in TextEncoding.required {
            #expect(encoding.isSupported)
        }
        #expect(TextEncoding(name: "UTF-8").isSupported, "names compare without case")
        #expect(TextEncoding(name: "x-rot13").isSupported, "one the platform adds")
        #expect(!TextEncoding(name: "shift_jis").isSupported)

        HostTextStorage.platform = nil
        #expect(TextBuffer.maximumLength == HostTextStorage.defaultMaximumLength)
        #expect(!TextEncoding(name: "x-rot13").isSupported)
    }

    @Test func withoutAPlatformATextIsHeldInMemory() {
        HostTextStorage.platform = nil
        let buffer = TextBuffer("one\ntwo")
        buffer.replace(0..<3, with: "1")
        #expect(buffer.string == "1\ntwo" && buffer.length == 5 && buffer.canUndo)
        let storage = HostTextStorage.storage(for: buffer.identifier)
        #expect(storage?.engine is MemoryTextEngine)
        #expect(platform.engines.isEmpty)
    }

    // MARK: Reading

    @Test func aTextIsMadeInTheHostWhenFirstUsed() throws {
        let buffer = TextBuffer("one\ntwo\n")
        #expect(platform.engines.isEmpty)
        #expect(buffer.length == 8 && !buffer.isModified && !buffer.canUndo && buffer.selection == 0..<0)
        #expect(platform.engines.isEmpty, "reading what it was made with makes nothing")

        #expect(buffer.string == "one\ntwo\n")
        let engine = try #require(platform.engines.last)
        #expect(engine.length == 8)
        #expect(!buffer.isModified && !buffer.canUndo, "the text it began with isn't an edit")
        #expect(HostTextStorage.storage(for: buffer.identifier)?.engine === engine)
        #expect(platform.engines.count == 1)

        #expect(buffer.substring(4..<7) == "two")
        #expect(buffer.substring(6..<100) == "o\n", "a range past the end is cut to the text")
        #expect(buffer.substring(50..<60) == "")
    }

    @Test func linesCountFromZeroAndEndAtNewlines() throws {
        let (buffer, _) = try made("one\ntwo\n\nfour")
        #expect(buffer.lineCount == 4)
        #expect(buffer.line(at: 0) == 0 && buffer.line(at: 3) == 0 && buffer.line(at: 4) == 1)
        #expect(buffer.line(at: 8) == 2 && buffer.line(at: 500) == 3)
        #expect(buffer.range(ofLine: 0) == 0..<4, "with its line break")
        #expect(buffer.range(ofLine: 2) == 8..<9)
        #expect(buffer.range(ofLine: 3) == 9..<13, "the last line ends with the text")
        #expect(buffer.range(ofLine: 4) == nil && buffer.range(ofLine: -1) == nil)
        #expect(TextBuffer().lineCount == 1, "an empty text has one line")
    }

    @Test func positionsStayOutOfSurrogatePairs() throws {
        // "a😀b": the face is two units, at 1 and 2.
        let (buffer, _) = try made("a😀b")
        #expect(buffer.length == 4)
        #expect(buffer.substring(1..<3) == "😀")
        #expect(buffer.substring(2..<4) == "😀b", "a start inside the pair moves back to it")
        #expect(buffer.substring(0..<2) == "a", "and so does an end")
        buffer.selection = 2..<4
        #expect(buffer.selection == 1..<4)
        buffer.replace(2..<2, with: "-")
        #expect(buffer.string == "a-😀b", "never between the halves")
    }

    // MARK: Editing

    @Test func theGuestsEditsAreUndoable() throws {
        let (buffer, engine) = try made("hello world")
        var edits: [TextEdit] = []
        buffer.onEdit = { edits.append($0) }

        buffer.replace(0..<5, with: "goodbye")
        #expect(buffer.string == "goodbye world" && buffer.length == 13)
        #expect(edits == [TextEdit(range: 0..<5, insertedLength: 7)])
        #expect(edits.last?.insertedRange == 0..<7)
        #expect(buffer.isModified && buffer.canUndo && !buffer.canRedo)

        buffer.replace(7..<13, with: "")
        #expect(buffer.string == "goodbye")
        buffer.replace(3..<3, with: "")
        #expect(edits.count == 2, "nothing for nothing isn't an edit")

        buffer.undo()
        #expect(buffer.string == "goodbye world" && buffer.canRedo)
        #expect(edits.last == TextEdit(range: 7..<7, insertedLength: 6), "an undo is an edit like any other")
        buffer.undo()
        #expect(buffer.string == "hello world" && !buffer.canUndo)
        #expect(buffer.isModified, "undoing back to where it began doesn't clear it")
        buffer.redo()
        #expect(buffer.string == "goodbye world" && buffer.canUndo)
        buffer.undo()
        buffer.undo()
        #expect(buffer.string == "hello world", "an undo with nothing to undo does nothing")
        #expect(engine.length == 11)
    }

    @Test func theSelectionFollowsTheGuestsEdits() throws {
        let (buffer, _) = try made("0123456789")
        var selections: [Range<Int>] = []
        buffer.onSelectionChange = { selections.append($0) }

        buffer.selection = 4..<6
        #expect(buffer.selection == 4..<6 && selections == [4..<6])
        buffer.selection = 4..<6
        #expect(selections.count == 1, "said once")

        buffer.replace(0..<2, with: "abcd")
        #expect(buffer.selection == 6..<8, "text before it grew")
        buffer.replace(8..<10, with: "")
        #expect(buffer.selection == 6..<8, "text after it doesn't move it")
        buffer.replace(5..<7, with: "x")
        #expect(buffer.string == "abcd2x589" && buffer.selection == 6..<7, "a start inside what was replaced goes after the new text")
        #expect(selections == [4..<6, 6..<8, 6..<7], "one report for each edit")

        buffer.selection = 3..<3
        buffer.insert("--")
        #expect(buffer.string == "abc--d2x589" && buffer.selection == 5..<5, "the caret is left after what's inserted")
        buffer.selection = 0..<3
        buffer.insert("X")
        #expect(buffer.string == "X--d2x589" && buffer.selection == 1..<1, "in place of what was selected")
        buffer.selection = 5..<500
        #expect(buffer.selection == 5..<9, "cut to the text")
    }

    @Test func theUsersTypingIsReported() throws {
        let (buffer, engine) = try made("ab")
        var edits: [TextEdit] = []
        buffer.onEdit = { edits.append($0) }
        #expect(!buffer.isModified)

        engine.selection = 2..<2
        #expect(buffer.selection == 2..<2)
        engine.type("c")
        #expect(buffer.length == 3 && buffer.isModified && buffer.canUndo)
        #expect(edits == [TextEdit(range: 2..<2, insertedLength: 1)])
        #expect(buffer.selection == 3..<3)
        #expect(buffer.string == "abc")

        engine.selection = 0..<2
        engine.type("😀")
        #expect(buffer.string == "😀c" && buffer.selection == 2..<2)
        engine.deleteBackward()
        #expect(buffer.string == "c", "a pair goes whole")
        buffer.undo()
        buffer.undo()
        #expect(buffer.string == "abc" && buffer.selection == 0..<2, "the guest undoes the user's typing")
    }

    @Test func aTextHoldsOnlyNewlines() throws {
        let buffer = TextBuffer("a\r\nb\rc\n")
        #expect(buffer.string == "a\nb\nc\n" && buffer.length == 6, "what it's made with")
        buffer.replace(6..<6, with: "d\r\ne")
        #expect(buffer.string == "a\nb\nc\nd\ne")
        buffer.string = "x\r\ny"
        #expect(buffer.string == "x\ny" && buffer.lineCount == 2)
        let engine = try #require(platform.engines.last)
        engine.selection = 3..<3
        engine.type("\r\nz")
        #expect(buffer.string == "x\ny\nz", "and what's typed or pasted")
    }

    @Test func aNewTextStartsOver() throws {
        let (buffer, _) = try made("old")
        buffer.replace(3..<3, with: "er")
        buffer.selection = 2..<4
        #expect(buffer.isModified && buffer.canUndo)
        var edits: [TextEdit] = []
        buffer.onEdit = { edits.append($0) }

        buffer.string = "brand new"
        #expect(buffer.string == "brand new" && buffer.length == 9)
        #expect(edits == [TextEdit(range: 0..<5, insertedLength: 9)], "one edit of everything")
        #expect(!buffer.isModified && !buffer.canUndo && !buffer.canRedo && buffer.selection == 0..<0)
        buffer.undo()
        #expect(buffer.string == "brand new", "its history went with the old text")
    }

    @Test func modifiedIsSaidWhenItChanges() throws {
        let (buffer, _) = try made("text")
        let storage = try #require(HostTextStorage.storage(for: buffer.identifier))
        #expect(!storage.isModified)
        buffer.replace(0..<0, with: "a")
        buffer.replace(0..<0, with: "b")
        #expect(buffer.isModified && storage.isModified)
        buffer.markSaved()
        #expect(!buffer.isModified && !storage.isModified)
        buffer.markSaved()
        buffer.replace(0..<1, with: "")
        #expect(buffer.isModified)
    }

    // MARK: Loading

    @Test func aFileIsReadIntoTheText() throws {
        try write(Array("first\r\nsecond\r\n".utf8), "windows.txt")
        let (buffer, engine) = try made("before")
        buffer.replace(0..<0, with: "x")
        var edits: [TextEdit] = []
        buffer.onEdit = { edits.append($0) }

        #expect(succeeded(load(buffer, "windows.txt")))
        #expect(buffer.string == "first\nsecond\n" && engine.length == 13)
        #expect(buffer.encoding == .utf8 && buffer.lineEnding == .crlf && !buffer.hasByteOrderMark)
        #expect(edits == [TextEdit(range: 0..<7, insertedLength: 13)], "one edit of everything")
        #expect(!buffer.isModified && !buffer.canUndo && buffer.selection == 0..<0 && !buffer.isLoading)

        try write([0xEF, 0xBB, 0xBF] + Array("marked\n".utf8), "marked.txt")
        #expect(succeeded(load(buffer, "marked.txt")))
        #expect(buffer.string == "marked\n" && buffer.encoding == .utf8 && buffer.hasByteOrderMark && buffer.lineEnding == .lf)

        try write([0xFF, 0xFE, 0x68, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x0D, 0x00], "wide.txt")
        #expect(succeeded(load(buffer, "wide.txt")))
        #expect(buffer.string == "h😀\n" && buffer.encoding == .utf16LittleEndian && buffer.hasByteOrderMark && buffer.lineEnding == .cr)

        try write([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69], "big.txt")
        #expect(succeeded(load(buffer, "big.txt")))
        #expect(buffer.string == "hi" && buffer.encoding == .utf16BigEndian)

        try write([0x00, 0x68, 0x00, 0x69], "bare.txt")
        #expect(succeeded(load(buffer, "bare.txt", encoding: .utf16BigEndian)))
        #expect(buffer.string == "hi" && !buffer.hasByteOrderMark, "an encoding the app names needs no mark")

        try write([], "empty.txt")
        #expect(succeeded(load(buffer, "empty.txt")))
        #expect(buffer.string == "" && buffer.lineEnding == .lf && buffer.lineCount == 1)
    }

    @Test func theHostDoesNotGuessAnEncoding() throws {
        // "café" in Latin-1: the é is one byte, which isn't UTF-8.
        try write([0x63, 0x61, 0x66, 0xE9], "latin.txt")
        let (buffer, _) = try made("kept")
        #expect(failure(load(buffer, "latin.txt")) == .undecodable)
        #expect(buffer.string == "kept" && buffer.encoding == .utf8, "a load that fails changes nothing")

        #expect(succeeded(load(buffer, "latin.txt", encoding: .isoLatin1)))
        #expect(buffer.string == "café" && buffer.encoding == .isoLatin1)

        try write([0x93, 0x68, 0x69, 0x94, 0x80], "quoted.txt")
        #expect(succeeded(load(buffer, "quoted.txt", encoding: .windows1252)))
        #expect(buffer.string == "\u{201C}hi\u{201D}€")
        #expect(succeeded(load(buffer, "quoted.txt", encoding: TextEncoding(name: "Windows-1252"))), "names compare without case")
        #expect(buffer.encoding == .windows1252)

        try write([0x68, 0x00, 0x69], "odd.txt")
        #expect(failure(load(buffer, "odd.txt", encoding: .utf16LittleEndian)) == .undecodable)
        try write([0x00, 0xD8, 0x68, 0x00], "lone.txt")
        #expect(failure(load(buffer, "lone.txt", encoding: .utf16LittleEndian)) == .undecodable, "half a pair isn't replaced")

        #expect(failure(load(buffer, "latin.txt", encoding: TextEncoding(name: "shift_jis"))) == .unsupportedEncoding)
        try write(Array("uryyb".utf8), "rotated.txt")
        #expect(succeeded(load(buffer, "rotated.txt", encoding: TextEncoding(name: "x-rot13"))))
        #expect(buffer.string == "hello", "the platform's own encoding")
        #expect(failure(load(buffer, "latin.txt", encoding: TextEncoding(name: "x-rot13"))) == .undecodable)
    }

    @Test func aLoadCanFail() throws {
        let (buffer, _) = try made("kept")
        #expect(failure(load(buffer, "missing.txt")) == .file(.notFound))
        #expect(failure(load(buffer, "../Home/secret.txt")) == .file(.invalidPath))
        try Foundation.FileManager.default.createDirectory(at: root.appendingPathComponent("Container/Documents/folder"), withIntermediateDirectories: true)
        #expect(failure(load(buffer, "folder")) == .file(.isDirectory))

        try write([UInt8](repeating: 0x61, count: 1001), "long.txt")
        #expect(failure(load(buffer, "long.txt")) == .tooLarge, "one unit more than this platform opens")
        try write([UInt8](repeating: 0x61, count: 1000), "fits.txt")
        #expect(succeeded(load(buffer, "fits.txt")))
        try write([UInt8](repeating: 0x61, count: 5000), "huge.txt")
        #expect(failure(load(buffer, "huge.txt")) == .tooLarge, "not read at all")
        #expect(buffer.length == 1000 && !buffer.isLoading)

        // A document the user picked is a directory like the app's own.
        try Data("the user's notes".utf8).write(to: root.appendingPathComponent("Home/picked.txt"))
        let granted = HostFiles.grant(HostFiles.Grant(path: root.appendingPathComponent("Home/picked.txt").path, kind: .file, isWritable: false))
        var result: Result<Void, TextError>?
        buffer.load(FilePath(granted)) { result = $0 }
        #expect(succeeded(result) && buffer.string == "the user's notes")
        buffer.save(to: FilePath(granted)) { result = $0 }
        #expect(failure(result) == .file(.readOnly), "given for reading")
        HostFiles.revoke(granted)
        buffer.load(FilePath(granted)) { result = $0 }
        #expect(failure(result) == .file(.notPermitted))
    }

    @Test func anotherLoadReplacesOneThatHasNotFinished() throws {
        try write(Array("first".utf8), "first.txt")
        try write(Array("second".utf8), "second.txt")
        let held = HeldWork()
        HostTextStorage.work = { held.jobs.append($0) }
        let (buffer, _) = try made("kept")

        var first: Result<Void, TextError>?
        var second: Result<Void, TextError>?
        buffer.load(.documents / "first.txt") { first = $0 }
        #expect(buffer.isLoading && buffer.string == "kept", "it keeps what it had until the file is read")
        buffer.load(.documents / "second.txt") { second = $0 }
        #expect(first == nil && second == nil && held.jobs.count == 2)

        held.runAll()
        #expect(failure(first) == .cancelled)
        #expect(succeeded(second) && buffer.string == "second" && !buffer.isLoading)
    }

    @Test func releasingABufferDestroysItsText() throws {
        try write(Array("first".utf8), "first.txt")
        let held = HeldWork()
        HostTextStorage.work = { held.jobs.append($0) }
        var result: Result<Void, TextError>?
        var identifier: Int32 = 0
        do {
            let buffer = TextBuffer("gone")
            identifier = buffer.identifier
            #expect(HostTextStorage.storage(for: identifier) != nil)
            buffer.load(.documents / "first.txt") { result = $0 }
        }
        #expect(HostTextStorage.storage(for: identifier) == nil)
        held.runAll()
        #expect(failure(result) == .cancelled, "and its load is cancelled")
    }

    // MARK: Saving

    @Test func theTextIsWrittenAsItsFileWas() throws {
        try write([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8), "notes.txt")
        let (buffer, _) = try made("")
        #expect(succeeded(load(buffer, "notes.txt")))
        buffer.replace(8..<8, with: "three\n")
        #expect(buffer.isModified)

        #expect(succeeded(save(buffer, "notes.txt")))
        #expect(try bytes("notes.txt") == [0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(!buffer.isModified && buffer.canUndo, "saving keeps the history")

        buffer.lineEnding = .lf
        buffer.hasByteOrderMark = false
        #expect(succeeded(save(buffer, "copies/unix.txt")))
        #expect(try bytes("copies/unix.txt") == Array("one\ntwo\nthree\n".utf8), "the directories above it are made")

        buffer.string = "hé\n"
        buffer.encoding = .utf16BigEndian
        buffer.hasByteOrderMark = true
        buffer.lineEnding = .cr
        #expect(succeeded(save(buffer, "wide.txt")))
        #expect(try bytes("wide.txt") == [0xFE, 0xFF, 0x00, 0x68, 0x00, 0xE9, 0x00, 0x0D])
        buffer.encoding = .utf16LittleEndian
        buffer.hasByteOrderMark = false
        #expect(succeeded(save(buffer, "wide.txt")))
        #expect(try bytes("wide.txt") == [0x68, 0x00, 0xE9, 0x00, 0x0D, 0x00])

        buffer.encoding = .isoLatin1
        buffer.hasByteOrderMark = true
        #expect(succeeded(save(buffer, "latin.txt")))
        #expect(try bytes("latin.txt") == [0x68, 0xE9, 0x0D], "Latin-1 has no mark to write")
        buffer.encoding = TextEncoding(name: "x-rot13")
        buffer.string = "hello"
        #expect(succeeded(save(buffer, "rotated.txt")))
        #expect(try bytes("rotated.txt") == Array("uryyb".utf8))
    }

    @Test func aSaveCanFail() throws {
        let (buffer, _) = try made("price: 5€ → 六")
        buffer.replace(0..<0, with: " ")
        try write(Array("untouched".utf8), "out.txt")

        buffer.encoding = .isoLatin1
        #expect(failure(save(buffer, "out.txt")) == .unencodable)
        buffer.encoding = .windows1252
        #expect(failure(save(buffer, "out.txt")) == .unencodable, "it has the euro, and not the arrow")
        buffer.encoding = TextEncoding(name: "x-rot13")
        #expect(failure(save(buffer, "out.txt")) == .unencodable)
        buffer.encoding = TextEncoding(name: "shift_jis")
        #expect(failure(save(buffer, "out.txt")) == .unsupportedEncoding)
        #expect(try bytes("out.txt") == Array("untouched".utf8), "nothing was written")
        #expect(buffer.isModified)

        buffer.encoding = .utf8
        #expect(failure(save(buffer, "../Home/out.txt")) == .file(.invalidPath))
        #expect(buffer.isModified)
        buffer.string = "5€"
        buffer.encoding = .windows1252
        #expect(succeeded(save(buffer, "out.txt")))
        #expect(try bytes("out.txt") == [0x35, 0x80])
    }

    @Test func whatIsTypedDuringASaveLeavesItModified() throws {
        let held = HeldWork()
        let (buffer, engine) = try made("draft")
        buffer.replace(5..<5, with: " one")
        HostTextStorage.work = { held.jobs.append($0) }

        var result: Result<Void, TextError>?
        buffer.save(to: .documents / "draft.txt") { result = $0 }
        engine.selection = 9..<9
        engine.type("!")
        held.runAll()
        #expect(succeeded(result))
        #expect(try bytes("draft.txt") == Array("draft one".utf8), "the text as it was when asked")
        #expect(buffer.isModified, "the file doesn't have the last key")

        buffer.save(to: .documents / "draft.txt") { result = $0 }
        held.runAll()
        #expect(!buffer.isModified)
        #expect(try bytes("draft.txt") == Array("draft one!".utf8))
    }

    // MARK: Searching

    func find(_ buffer: TextBuffer, _ text: String, _ options: TextSearchOptions = [], from position: Int? = nil) -> Range<Int>? {
        var found: Range<Int>?
        buffer.find(text, options: options, from: position) { found = $0 }
        return found
    }

    @Test func theHostSearchesItsText() throws {
        let (buffer, _) = try made("The cat sat on the mat. Catalog: the CAT.")
        #expect(find(buffer, "the") == 15..<18, "from the caret, which is at the start")
        #expect(find(buffer, "the", [.caseInsensitive]) == 0..<3)
        buffer.selection = 0..<3
        #expect(find(buffer, "the", [.caseInsensitive]) == 15..<18, "from the selection's end")
        #expect(find(buffer, "cat", [.caseInsensitive], from: 5) == 24..<27)
        #expect(find(buffer, "cat", [.caseInsensitive, .wholeWords], from: 5) == 37..<40, "Catalog isn't the word")
        #expect(find(buffer, "dog") == nil && find(buffer, "") == nil)

        #expect(find(buffer, "the", from: 20) == 33..<36)
        #expect(find(buffer, "the", from: 34) == nil)
        #expect(find(buffer, "the", [.wraps], from: 34) == 15..<18, "from the start again")

        buffer.selection = 15..<18
        #expect(find(buffer, "The", [.backwards]) == 0..<3, "from the selection's start")
        #expect(find(buffer, "the", [.backwards], from: 36) == 33..<36, "a match that ends where it starts from")
        #expect(find(buffer, "the", [.backwards], from: 10) == nil)
        #expect(find(buffer, "the", [.backwards, .wraps], from: 10) == 33..<36, "from the end again")

        let accented = TextBuffer("Élan élan\nnext")
        #expect(find(accented, "élan", [.caseInsensitive]) == 0..<4, "case folds outside ASCII")
        #expect(find(accented, "elan", [.caseInsensitive]) == nil, "and accents count")
        #expect(find(accented, "élan\r\nnext") == 5..<14, "a query's line break is the text's")
    }

    @Test func replacingAllIsOneEdit() throws {
        let (buffer, _) = try made("a colour, a Colour, a color")
        var edits: [TextEdit] = []
        buffer.onEdit = { edits.append($0) }
        buffer.selection = 10..<10

        var count: Int?
        buffer.replaceAll("colour", with: "color", options: [.caseInsensitive]) { count = $0 }
        #expect(count == 2 && buffer.string == "a color, a color, a color")
        #expect(edits == [TextEdit(range: 2..<18, insertedLength: 14)], "from the first match to the last")
        #expect(buffer.selection == 16..<16, "the caret was inside what was replaced")
        buffer.undo()
        #expect(buffer.string == "a colour, a Colour, a color" && !buffer.canUndo, "one undo step")

        buffer.replaceAll("zebra", with: "horse") { count = $0 }
        #expect(count == 0 && edits.count == 2 && !buffer.canUndo, "nothing matched, nothing changed")
        buffer.replaceAll("a", with: "aa") { count = $0 }
        #expect(count == 3 && buffer.string == "aa colour, aa Colour, aa color", "a replacement isn't searched again")
        buffer.replaceAll("aa ", with: "") { count = $0 }
        #expect(count == 3 && buffer.string == "colour, Colour, color")
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func callsCanBeAwaited() async throws {
        HostTextStorage.work = { job in DispatchQueue.global().async(execute: job) }
        HostTextStorage.deliver = { DispatchQueue.main.async(execute: $0) }
        try write(Array("needle in a haystack\r\n".utf8), "hay.txt")
        let buffer = TextBuffer()
        try await buffer.load(.documents / "hay.txt")
        #expect(buffer.string == "needle in a haystack\n" && buffer.lineEnding == .crlf)

        let match = await buffer.find("hay")
        #expect(match == 12..<15)
        #expect(await buffer.find("pin") == nil)
        let count = await buffer.replaceAll("a", with: "A")
        #expect(count == 3)
        try await buffer.save(to: .documents / "hay.txt")
        #expect(try bytes("hay.txt") == Array("needle in A hAystAck\r\n".utf8))
        #expect(!buffer.isModified)

        do {
            try await buffer.load(.documents / "none.txt")
            Issue.record("a missing file loaded")
        } catch {
            #expect(error == .file(.notFound))
        }
    }

    @MainActor @Test func editsAreAStream() async throws {
        let (buffer, engine) = try made("ab")
        let stream = buffer.edits
        let reader = Task { @MainActor in
            var seen: [TextEdit] = []
            for await edit in stream {
                seen.append(edit)
                if seen.count == 2 { break }
            }
            return seen
        }
        await Task.yield()
        buffer.replace(0..<1, with: "xyz")
        engine.type("!")
        let seen = await reader.value
        #expect(seen == [TextEdit(range: 0..<1, insertedLength: 3), TextEdit(range: 3..<3, insertedLength: 1)])
    }

    // MARK: The view

    @Test func theNodeNamesTheText() throws {
        let (buffer, engine) = try made("shown")
        let sink = TextSink()
        let graph = ViewGraph(Editor(buffer: buffer), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.first("TextEditor"))
        #expect(node.props["buffer"] == .int(Int(buffer.identifier)))
        #expect(node.props["editable"] == false && node.props["wraps"] == false)
        #expect(sink.screen?.first("Text")?.props["text"] == "Saved")

        engine.type("!")
        graph.update()
        #expect(sink.screen?.first("Text")?.props["text"] == "Edited", "a view that reads the buffer follows it")
        #expect(sink.screen?.first("TextEditor")?.id == node.id, "the same node: the host keeps its text view")
    }

    @Test func aBufferFirstUsedByItsViewChangesNothingMidUpdate() throws {
        let buffer = TextBuffer("made\r\nhere")
        let sink = TextSink()
        let graph = ViewGraph(Editor(buffer: buffer), sink: sink)
        graph.update()
        #expect(platform.engines.count == 1, "showing it made it")
        #expect(!graph.needsUpdate, "what the host said back of its first text isn't a change")
        #expect(buffer.length == 9 && !buffer.isModified)
    }

    @Test func aBindingKeepsItsOwnBuffer() throws {
        let draft = Draft()
        let sink = TextSink()
        let graph = ViewGraph(Composer(draft: draft), sink: sink)
        graph.update()
        let engine = try #require(platform.engines.last)
        let node = try #require(sink.screen?.first("TextEditor"))
        #expect(node.props["editable"] == true && node.props["wraps"] == true)
        #expect(engine.text(in: 0..<engine.length) == "Hello")
        #expect(HostTextStorage.storage(for: Int32(node.props["buffer"]?.int ?? 0))?.engine === engine)

        engine.selection = 5..<5
        engine.type(", world")
        #expect(draft.message == "Hello, world", "the whole text, after each change")
        graph.setNeedsUpdate()
        graph.update()
        #expect(platform.engines.count == 1 && engine.length == 12, "what it typed itself isn't sent back")
        #expect(sink.screen?.first("TextEditor")?.props["buffer"] == node.props["buffer"])

        draft.message = "Cleared"
        graph.setNeedsUpdate()
        graph.update()
        #expect(engine.text(in: 0..<engine.length) == "Cleared", "the app changed the binding: a new text")
        #expect(draft.message == "Cleared")
        engine.undo()
        #expect(engine.text(in: 0..<engine.length) == "Cleared", "with no history")
    }

    @Test func aBindingFollowsTheSelection() throws {
        let draft = Draft()
        draft.message = "a😀b"
        let sink = TextSink()
        let graph = ViewGraph(SelectingComposer(draft: draft), sink: sink)
        graph.update()
        let engine = try #require(platform.engines.last)
        #expect(draft.selection == nil)

        engine.selection = 1..<3
        let selected = try #require(draft.selection)
        guard case .selection(let range) = selected.indices else { return }
        #expect(String(draft.message[range]) == "😀" && !selected.isInsertion)

        engine.selection = 4..<4
        engine.type("!")
        #expect(draft.message == "a😀b!")
        #expect(draft.selection == TextSelection(insertionPoint: draft.message.endIndex))
        #expect(draft.selection?.isInsertion == true)

        // The app moves it.
        draft.selection = TextSelection(range: draft.message.startIndex ..< draft.message.index(after: draft.message.startIndex))
        graph.setNeedsUpdate()
        graph.update()
        #expect(engine.selection == 0..<1)
        draft.selection = TextSelection(insertionPoint: draft.message.index(draft.message.startIndex, offsetBy: 2))
        graph.setNeedsUpdate()
        graph.update()
        #expect(engine.selection == 3..<3, "after the face, which is two units")
    }

    // MARK: Coding

    @Test func everyByteOfWindows1252ReadsAndWritesBack() throws {
        let all = (0...255).map { UInt8($0) }
        let decoded = try TextCoding.decode(all, encoding: "windows-1252")
        // 0x0D is a line break, which a text holds as `\n`. 0x0A comes
        // first.
        #expect(decoded.text.unicodeScalars.count == 256 && decoded.lineEnding == .lf)
        let written = try TextCoding.encode(decoded.text, encoding: "windows-1252", lineEnding: .lf, byteOrderMark: false)
        var expected = all
        expected[0x0D] = 0x0A
        #expect(written == expected)
        #expect(try TextCoding.decode([0x80, 0x99], encoding: "windows-1252").text == "€™")
        #expect(try TextCoding.decode([0x80, 0x99], encoding: "iso-8859-1").text == "\u{80}\u{99}")
    }

    @Test func lineBreaksAreFoundAndConverted() {
        #expect(TextCoding.normalizingLineBreaks("a\nb\r\nc").lineEnding == .lf, "the first kind")
        #expect(TextCoding.normalizingLineBreaks("a\rb\nc").text == "a\nb\nc")
        #expect(TextCoding.normalizingLineBreaks("a\rb\nc").lineEnding == .cr)
        #expect(TextCoding.normalizingLineBreaks("a\r\n\r\nb\r").text == "a\n\nb\n")
        #expect(TextCoding.normalizingLineBreaks("none").lineEnding == .lf)
        #expect(TextCoding.applying(.crlf, to: "a\n\nb") == "a\r\n\r\nb")
        #expect(TextCoding.applying(.cr, to: "a\nb\n") == "a\rb\r")
    }

    @Test func aMarkIsTakenOnlyForItsOwnEncoding() throws {
        let marked: [UInt8] = [0xEF, 0xBB, 0xBF, 0x68]
        #expect(try TextCoding.decode(marked, encoding: "").hasByteOrderMark)
        #expect(try TextCoding.decode(marked, encoding: "utf-8").text == "h")
        let latin = try TextCoding.decode(marked, encoding: "iso-8859-1")
        #expect(latin.text == "ï»¿h" && !latin.hasByteOrderMark, "in Latin-1 those are three letters")
        #expect(throws: TextError.undecodable) { try TextCoding.decode([0xC3], encoding: "utf-8") }
        #expect(throws: TextError.unsupportedEncoding) { try TextCoding.decode([0x68], encoding: "koi8-r") }
        #expect(try TextCoding.encode("h", encoding: "", lineEnding: .lf, byteOrderMark: true) == marked, "no name is UTF-8")
    }

    @Test func positionsMoveWithAnEdit() {
        // Three units at 4 became one.
        #expect(TextPositions.adjusting(2, forEditAt: 4, removed: 3, inserted: 1) == 2)
        #expect(TextPositions.adjusting(4, forEditAt: 4, removed: 3, inserted: 1) == 5)
        #expect(TextPositions.adjusting(6, forEditAt: 4, removed: 3, inserted: 1) == 5)
        #expect(TextPositions.adjusting(7, forEditAt: 4, removed: 3, inserted: 1) == 5)
        #expect(TextPositions.adjusting(9, forEditAt: 4, removed: 3, inserted: 1) == 7)
        #expect(TextPositions.adjusting(4, forEditAt: 4, removed: 0, inserted: 2) == 6, "a caret where text is inserted goes after it")
    }
}
