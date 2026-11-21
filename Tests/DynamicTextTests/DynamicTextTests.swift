import Testing
import DynamicFiles
import DynamicRuntime
import DynamicText
import RuntimeCore
import RuntimeNative

/// A host's text that only writes down what it's asked, and keeps its
/// delegate and callbacks for the test to answer through.
final class ScriptedStorage: TextStorage {

    nonisolated(unsafe) static var all: [ScriptedStorage] = []

    nonisolated(unsafe) static var destroyed: [Int32] = []

    static var last: ScriptedStorage? { all.last }

    let delegate: any TextStorageDelegate

    let id: Int32

    var calls: [String] = []

    var callbacks: [any TextCallback] = []

    var content = "host text"

    init(delegate: any TextStorageDelegate) {
        self.delegate = delegate
        self.id = Int32(Self.all.count + 1)
    }

    deinit {
        Self.destroyed.append(id)
    }

    static func make(_ delegate: any TextStorageDelegate) -> ScriptedStorage {
        let storage = ScriptedStorage(delegate: delegate)
        all.append(storage)
        return storage
    }

    static func maximumLength() -> Int32 { 4096 }

    static func supportsEncoding(_ name: String) -> Bool { name == "utf-8" || name == "big5" }

    func identifier() -> Int32 { id }
    func length() -> Int32 { Int32(content.utf16.count) }
    func text() -> String { content }
    func substring(_ location: Int32, length: Int32) -> String {
        calls.append("substring \(location) \(length)")
        return "part"
    }
    func lineCount() -> Int32 { 3 }
    func line(_ location: Int32) -> Int32 {
        calls.append("line \(location)")
        return 1
    }
    func lineStart(_ line: Int32) -> Int32 {
        switch line {
        case 0: 0
        case 1: 4
        case 2: 7
        default: -1
        }
    }
    func setText(_ text: String) { calls.append("setText \(text)") }
    func replace(_ location: Int32, length: Int32, text: String) { calls.append("replace \(location) \(length) \(text)") }
    func setSelection(_ location: Int32, length: Int32) { calls.append("setSelection \(location) \(length)") }
    func undo() { calls.append("undo") }
    func redo() { calls.append("redo") }
    func setModified(_ modified: Bool) { calls.append("setModified \(modified)") }
    func reveal(_ location: Int32, length: Int32) { calls.append("reveal \(location) \(length)") }

    func load(_ directory: Int32, path: String, encoding: String, callback: any TextCallback) {
        calls.append("load \(directory) \(path) [\(encoding)]")
        callbacks.append(callback)
    }

    func save(_ directory: Int32, path: String, encoding: String, lineEnding: Int32, byteOrderMark: Bool, callback: any TextCallback) {
        calls.append("save \(directory) \(path) [\(encoding)] \(lineEnding) \(byteOrderMark)")
        callbacks.append(callback)
    }

    func find(_ text: String, options: Int32, from location: Int32, callback: any TextCallback) {
        calls.append("find \(text) \(options) \(location)")
        callbacks.append(callback)
    }

    func replaceAll(_ text: String, with replacement: String, options: Int32, callback: any TextCallback) {
        calls.append("replaceAll \(text) \(replacement) \(options)")
        callbacks.append(callback)
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// list of texts.
@Suite(.serialized) final class DynamicTextTests {

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        TextStorageProxy.register(ScriptedStorage.self, in: native)
        TextStorageDelegateProxy.registerInterface(in: native)
        TextCallbackProxy.registerInterface(in: native)
        ScriptedStorage.all = []
        ScriptedStorage.destroyed = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    /// A buffer the host has, and its host.
    func made() throws -> (TextBuffer, ScriptedStorage) {
        let buffer = TextBuffer()
        _ = buffer.identifier
        return (buffer, try #require(ScriptedStorage.last))
    }

    // MARK: Contracts

    @Test func aTextNeedsNoCapability() {
        let storage = TextStorageProxy.descriptor
        #expect(storage.name == "org.pureswift.text.Storage")
        #expect(storage.capability == nil)
        #expect(method(storage, "make:")?.kind == .constructor)
        #expect(method(storage, "maximumLength")?.signature == Signature("()I"))
        #expect(method(storage, "supportsEncoding:")?.signature == Signature("(O)Z"))
        #expect(method(storage, "text")?.signature == Signature("()O"))
        #expect(method(storage, "substring:length:")?.signature == Signature("(II)O"))
        #expect(method(storage, "lineStart:")?.signature == Signature("(I)I"))
        #expect(method(storage, "replace:length:text:")?.signature == Signature("(IIO)V"))
        #expect(method(storage, "load:path:encoding:callback:")?.signature == Signature("(IOOO)V"))
        #expect(method(storage, "save:path:encoding:lineEnding:byteOrderMark:callback:")?.signature == Signature("(IOOIZO)V"))
        #expect(method(storage, "find:options:from:callback:")?.signature == Signature("(OIIO)V"))
        #expect(method(storage, "replaceAll:with:options:callback:")?.signature == Signature("(OOIO)V"))
        #expect(storage.methods.count == 21)

        let delegate = TextStorageDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.text.StorageDelegate" && delegate.kind == .callback)
        #expect(method(delegate, "didEdit:removed:inserted:length:")?.signature == Signature("(IIII)V"))
        #expect(method(delegate, "didChangeUndo:canRedo:")?.signature == Signature("(ZZ)V"))
        #expect(delegate.methods.count == 4)

        let callback = TextCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.text.Callback" && callback.kind == .callback)
        #expect(method(callback, "didLoad:lineEnding:byteOrderMark:")?.signature == Signature("(OIZ)V"))
        #expect(method(callback, "didFail:file:")?.signature == Signature("(II)V"))
        #expect(callback.methods.count == 5)

        let descriptors = [storage, delegate, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Types

    @Test func namesCompareWithoutCase() {
        #expect(TextEncoding(name: "UTF-8") == .utf8)
        #expect(TextEncoding(rawValue: "Windows-1252") == .windows1252)
        #expect(TextEncoding(name: "Shift_JIS").name == "shift_jis")
        #expect(TextEncoding.required.map(\.rawValue) == ["utf-8", "utf-16le", "utf-16be", "iso-8859-1", "windows-1252"])
        #expect(TextEncoding.utf8.isSupported && TextEncoding(name: "BIG5").isSupported)
        #expect(!TextEncoding.isoLatin1.isSupported, "the host says, even for one it should have")
        #expect(TextBuffer.maximumLength == 4096)
    }

    @Test func errorsCrossAsTwoNumbers() {
        let all: [TextError] = [.unknown, .file(.notFound), .undecodable, .unencodable, .unsupportedEncoding, .tooLarge, .cancelled]
        for error in all {
            #expect(TextError(code: error.code.rawValue, file: error.fileCode) == error)
        }
        #expect(TextError.file(.readOnly).fileCode == FileError.readOnly.rawValue && TextError.tooLarge.fileCode == 0)
        #expect(TextError(code: 99, file: 0) == .unknown, "a code from a newer host")
        #expect(TextError(code: 1, file: 99) == .file(.unknown), "and a file error from one")
        #expect(TextSearchOptions([.caseInsensitive, .backwards, .wholeWords, .wraps]).rawValue == 15)
        #expect(LineEnding.lf.rawValue == 0 && LineEnding.crlf.rawValue == 1 && LineEnding.cr.rawValue == 2)
        #expect(TextEdit(range: 4..<9, insertedLength: 2).insertedRange == 4..<6)
    }

    // MARK: The buffer

    @Test func theBufferAsksTheHost() throws {
        let buffer = TextBuffer()
        #expect(ScriptedStorage.all.isEmpty)
        #expect(buffer.length == 0 && buffer.selection == 0..<0 && !buffer.isModified && !buffer.isLoading)
        #expect(buffer.encoding == .utf8 && buffer.lineEnding == .lf && !buffer.hasByteOrderMark)
        #expect(ScriptedStorage.all.isEmpty, "reading it makes nothing")

        #expect(buffer.string == "host text")
        let host = try #require(ScriptedStorage.last)
        #expect(host.calls.isEmpty, "an empty buffer sends no first text")
        #expect(buffer.identifier == host.id)

        #expect(buffer.substring(2..<6) == "part")
        buffer.string = "new"
        buffer.replace(1..<4, with: "x")
        buffer.selection = 3..<8
        buffer.undo()
        buffer.redo()
        buffer.markSaved()
        buffer.reveal(10..<12)
        #expect(buffer.line(at: 5) == 1)
        #expect(host.calls == [
            "substring 2 4", "setText new", "replace 1 3 x", "setSelection 3 5", "undo", "redo",
            "setModified false", "reveal 10 2", "line 5",
        ])
        #expect(buffer.lineCount == 3)
        #expect(buffer.range(ofLine: 1) == 4..<7 && buffer.range(ofLine: 2) == 7..<9, "the last line ends with the text")
        #expect(buffer.range(ofLine: 3) == nil)
        #expect(ScriptedStorage.all.count == 1)
    }

    @Test func aBufferMadeWithATextSendsItOnce() throws {
        let buffer = TextBuffer("a\r\nb")
        #expect(buffer.length == 3, "as the host will hold it")
        _ = buffer.identifier
        let host = try #require(ScriptedStorage.last)
        #expect(host.calls == ["setText a\nb"])
        _ = buffer.identifier
        buffer.undo()
        #expect(host.calls == ["setText a\nb", "undo"])
    }

    @Test func theBufferFollowsWhatTheHostReports() throws {
        let (buffer, host) = try made()
        var edits: [TextEdit] = []
        var selections: [Range<Int>] = []
        buffer.onEdit = { edits.append($0) }
        buffer.onSelectionChange = { selections.append($0) }

        host.delegate.didEdit(4, removed: 2, inserted: 5, length: 12)
        #expect(buffer.length == 12 && edits == [TextEdit(range: 4..<6, insertedLength: 5)])
        host.delegate.didChangeSelection(9, length: 0)
        host.delegate.didChangeSelection(9, length: 0)
        #expect(buffer.selection == 9..<9 && selections == [9..<9], "the same selection isn't news")
        host.delegate.didChangeModified(true)
        #expect(buffer.isModified)
        host.delegate.didChangeUndo(true, canRedo: false)
        #expect(buffer.canUndo && !buffer.canRedo)
        host.delegate.didChangeUndo(false, canRedo: true)
        #expect(!buffer.canUndo && buffer.canRedo)
        host.delegate.didChangeModified(false)
        #expect(!buffer.isModified)

        // What no host should send is taken as nothing.
        host.delegate.didEdit(-3, removed: -1, inserted: -1, length: -5)
        #expect(buffer.length == 0 && edits.last == TextEdit(range: 0..<0, insertedLength: 0))
        host.delegate.didChangeSelection(-2, length: -4)
        #expect(buffer.selection == 0..<0)
    }

    @Test func aReleasedBufferDestroysTheHostsText() throws {
        var delegate: (any TextStorageDelegate)?
        do {
            let (buffer, host) = try made()
            delegate = host.delegate
            #expect(ScriptedStorage.destroyed.isEmpty)
            _ = buffer
        }
        ScriptedStorage.all = []
        #expect(ScriptedStorage.destroyed == [1])
        // A host that reports late reaches nothing.
        delegate?.didEdit(0, removed: 0, inserted: 1, length: 1)
    }

    // MARK: Files

    @Test func aLoadSaysWhatTheFileWas() throws {
        let (buffer, host) = try made()
        var results: [Result<Void, TextError>] = []
        buffer.load(.documents / "notes/a.txt") { results.append($0) }
        #expect(buffer.isLoading)
        buffer.load(FilePath(FileDirectory(rawValue: 300)), encoding: TextEncoding(name: "Big5")) { results.append($0) }
        #expect(host.calls == ["load 0 notes/a.txt []", "load 300  [big5]"], "no encoding is the empty name")

        host.callbacks[0].didFail(TextError.Code.cancelled.rawValue, file: 0)
        #expect(buffer.isLoading, "the second is still under way")
        #expect(results.count == 1 && buffer.encoding == .utf8)
        host.callbacks[1].didLoad("big5", lineEnding: 1, byteOrderMark: true)
        #expect(!buffer.isLoading && results.count == 2)
        #expect(buffer.encoding == TextEncoding(name: "big5") && buffer.lineEnding == .crlf && buffer.hasByteOrderMark)
        host.callbacks[1].didFail(0, file: 0)
        #expect(results.count == 2, "only a host's first answer counts")
        if case .failure(let error) = results[0] { #expect(error == .cancelled) } else { Issue.record("the first load succeeded") }
        if case .failure = results[1] { Issue.record("the second load failed") }

        buffer.load(.documents / "b.txt") { results.append($0) }
        host.callbacks[2].didLoad("utf-8", lineEnding: 7, byteOrderMark: false)
        #expect(buffer.lineEnding == .lf, "a line ending from a newer host")
        buffer.load(.documents / "c.txt") { results.append($0) }
        host.callbacks[3].didComplete()
        if case .failure(let error) = results[3] { #expect(error == .unknown) } else { Issue.record("an answer of the wrong kind succeeded") }
        buffer.load(.documents / "d.txt") { results.append($0) }
        host.callbacks[4].didFail(1, file: FileError.notFound.rawValue)
        if case .failure(let error) = results[4] { #expect(error == .file(.notFound)) } else { Issue.record("a missing file loaded") }
        #expect(!buffer.isLoading)
    }

    @Test func aSaveWritesTheBuffersFormat() throws {
        let (buffer, host) = try made()
        var results: [Result<Void, TextError>] = []
        buffer.save(to: .documents / "a.txt") { results.append($0) }
        buffer.encoding = .utf16LittleEndian
        buffer.lineEnding = .crlf
        buffer.hasByteOrderMark = true
        buffer.save(to: .caches / "b.txt") { results.append($0) }
        #expect(host.calls == ["save 0 a.txt [utf-8] 0 false", "save 2 b.txt [utf-16le] 1 true"])
        host.callbacks[0].didComplete()
        host.callbacks[1].didFail(TextError.Code.unencodable.rawValue, file: 0)
        if case .failure = results[0] { Issue.record("the save failed") }
        if case .failure(let error) = results[1] { #expect(error == .unencodable) } else { Issue.record("the save succeeded") }
    }

    // MARK: Searching

    @Test func aSearchStartsFromTheSelection() throws {
        let (buffer, host) = try made()
        host.delegate.didChangeSelection(10, length: 5)
        var found: [Range<Int>?] = []
        buffer.find("x") { found.append($0) }
        buffer.find("x", options: [.backwards, .wraps]) { found.append($0) }
        buffer.find("x", options: .caseInsensitive, from: 2) { found.append($0) }
        #expect(host.calls == ["find x 0 15", "find x 10 10", "find x 1 2"], "its end, or its start going backwards")
        host.callbacks[0].didFind(20, length: 1)
        host.callbacks[1].didFind(-1, length: 0)
        host.callbacks[2].didComplete()
        #expect(found == [20..<21, nil, nil], "an answer of the wrong kind found nothing")

        var counts: [Int] = []
        buffer.replaceAll("a", with: "b", options: .wholeWords) { counts.append($0) }
        buffer.replaceAll("a", with: "b") { counts.append($0) }
        #expect(host.calls.suffix(2) == ["replaceAll a b 4", "replaceAll a b 0"])
        host.callbacks[3].didReplace(6)
        host.callbacks[4].didReplace(-2)
        #expect(counts == [6, 0])
    }
}
