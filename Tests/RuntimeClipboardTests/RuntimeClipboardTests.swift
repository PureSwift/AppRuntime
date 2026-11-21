import Foundation
import Testing
import DynamicClipboard
import DynamicFiles
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeClipboard

/// A platform's clipboard the test fills as another app would, and which
/// refuses, waits and misbehaves when the test says.
final class TestClipboard: ClipboardPlatform {

    var content: HostClipboardContent?

    var isSensitive = false

    /// What `available` says, when it isn't what's there.
    var says: ClipboardKinds?

    /// The user's answer to "Allow Paste?", or the platform's.
    var refusesReads = false

    var writeError: PasteboardError?

    /// Reads wait for the user here until the test answers them.
    var asksFirst = false

    var waiting: [() -> Void] = []

    var answersTwice = false

    var reads: [ClipboardKind] = []

    var writes = 0

    func available() -> ClipboardKinds {
        if let says { return says }
        switch content {
        case nil: return []
        case .text(_, let url): return url == nil ? .text : [.text, .url]
        case .image: return .image
        }
    }

    func clear() {
        content = nil
    }

    func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        writes += 1
        if let writeError {
            completion(writeError)
            return
        }
        self.content = content
        self.isSensitive = isSensitive
        completion(nil)
        if answersTwice { completion(.unknown) }
    }

    func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        reads.append(kind)
        let answer: Result<HostClipboardContent?, PasteboardError>
        if refusesReads {
            answer = .failure(.notAllowed)
        } else {
            switch (kind, content) {
            case (.text, .text), (.image, .image):
                answer = .success(content)
            case (.url, .text(_, let url)) where url != nil:
                answer = .success(content)
            default:
                answer = .success(nil)
            }
        }
        let finish = {
            completion(answer)
            if self.answersTwice { completion(.failure(.unknown)) }
        }
        if asksFirst {
            waiting.append(finish)
        } else {
            finish()
        }
    }
}

/// `HostClipboard` over a clipboard the test keeps and real files, driven
/// from the guest's `Pasteboard` through the runtime.
///
/// Serialized: `HostClipboard`, `HostFiles` and the native runtime are
/// shared.
@Suite(.serialized) final class RuntimeClipboardTests {

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]

    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7]

    let platform = TestClipboard()

    let pasteboard = Pasteboard.general

    let root: URL

    init() throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("RuntimeClipboardTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try manager.createDirectory(at: root.appendingPathComponent("Container/Documents"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("App/resources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Home"), withIntermediateDirectories: true)
        try Data(Self.png).write(to: root.appendingPathComponent("App/resources/logo.png"))
        try Data(Self.jpeg).write(to: root.appendingPathComponent("Container/Documents/photo.jpg"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("Container/Documents/notes.txt"))

        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Container/Documents").path,
            .caches: root.appendingPathComponent("Container/Caches").path,
            .bundle: root.appendingPathComponent("App/resources").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostClipboard.reset()
        HostClipboard.platform = platform
        HostClipboard.work = { $0() }
        HostClipboard.deliver = { $0() }
        HostClipboardModule.register(in: native)
    }

    deinit {
        HostClipboard.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func onDisk(_ path: String) -> [UInt8]? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { [UInt8]($0) }
    }

    func string() -> Result<String?, PasteboardError>? {
        var result: Result<String?, PasteboardError>?
        pasteboard.string { result = $0 }
        return result
    }

    func url() -> Result<String?, PasteboardError>? {
        var result: Result<String?, PasteboardError>?
        pasteboard.url { result = $0 }
        return result
    }

    func image() -> Result<PasteboardImage?, PasteboardError>? {
        var result: Result<PasteboardImage?, PasteboardError>?
        pasteboard.image { result = $0 }
        return result
    }

    func image(to path: FilePath) -> Result<PasteboardImageType?, PasteboardError>? {
        var result: Result<PasteboardImageType?, PasteboardError>?
        pasteboard.image(to: path) { result = $0 }
        return result
    }

    func copy(_ body: (@escaping (Result<Void, PasteboardError>) -> Void) -> Void) -> PasteboardError?? {
        var result: Result<Void, PasteboardError>?
        body { result = $0 }
        switch result {
        case nil: return nil
        case .success: return .some(nil)
        case .failure(let error): return .some(error)
        }
    }

    /// `nil`: a value, or nothing to paste. Otherwise why it failed.
    func error<Value>(_ result: Result<Value, PasteboardError>?) -> PasteboardError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func value<Value>(_ result: Result<Value?, PasteboardError>?) -> Value? {
        if case .success(let value)? = result { return value }
        return nil
    }

    static let succeeded: PasteboardError?? = .some(nil)

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostClipboardModule.contracts.map(\.name) == ["org.pureswift.clipboard.Clipboard", "org.pureswift.clipboard.Callback"])
        #expect(HostClipboardModule.permissionProviders().isEmpty, "nothing is declared for a clipboard")
        #expect(HostClipboard.shared() === HostClipboard.shared())
    }

    @Test func withoutAPlatformTheAppHasAClipboardOfItsOwn() {
        HostClipboard.platform = nil
        #expect(!pasteboard.hasStrings)
        pasteboard.setURL("https://swift.org", title: "Swift", options: .sensitive)
        #expect(pasteboard.hasStrings && pasteboard.hasURLs && !pasteboard.hasImages)
        #expect(value(string()) == "Swift" && value(url()) == "https://swift.org")
        #expect(HostClipboard.memory.content == .text("Swift", url: "https://swift.org") && HostClipboard.memory.isSensitive)
        pasteboard.setImage(Self.png, type: .png)
        #expect(pasteboard.hasImages && !pasteboard.hasStrings, "a write replaces everything")
        #expect(value(image()) == PasteboardImage(data: Self.png, type: .png) && value(string()) == nil)
        #expect(!HostClipboard.memory.isSensitive)
        pasteboard.clear()
        #expect(!pasteboard.hasImages && value(image()) == nil)
        #expect(platform.writes == 0 && platform.reads.isEmpty, "none of it reached another app")
    }

    // MARK: Text

    @Test func copiedTextReplacesWhatWasThere() {
        platform.content = .image(Self.png, type: .png)
        #expect(copy { pasteboard.setString("42", completion: $0) } == Self.succeeded)
        #expect(platform.content == .text("42", url: nil) && !platform.isSensitive)
        pasteboard.setString("hunter2", options: .sensitive)
        #expect(platform.content == .text("hunter2", url: nil) && platform.isSensitive)
        pasteboard.setString("")
        #expect(platform.content == .text("", url: nil) && !platform.isSensitive)

        pasteboard.setURL("https://swift.org", title: "Swift")
        #expect(platform.content == .text("Swift", url: "https://swift.org"))
        pasteboard.setURL("https://swift.org")
        #expect(platform.content == .text("https://swift.org", url: "https://swift.org"), "a URL is always text too")
        #expect(copy { pasteboard.clear(completion: $0) } == Self.succeeded)
        #expect(platform.content == nil)
    }

    @Test func lookingNeverReads() {
        #expect(!pasteboard.hasStrings && !pasteboard.hasURLs && !pasteboard.hasImages)
        platform.content = .text("from another app", url: nil)
        #expect(pasteboard.hasStrings && !pasteboard.hasURLs)
        platform.content = .text("Swift", url: "https://swift.org")
        #expect(pasteboard.hasStrings && pasteboard.hasURLs)
        platform.content = .image(Self.jpeg, type: .jpeg)
        #expect(pasteboard.hasImages && !pasteboard.hasStrings)
        // A platform that can't look without asking says there may be anything.
        platform.content = nil
        platform.says = .all
        #expect(pasteboard.hasStrings && pasteboard.hasURLs && pasteboard.hasImages)
        #expect(platform.reads.isEmpty)
    }

    @Test func pastedTextIsWhatIsThere() {
        #expect(value(string()) == nil && error(string()) == nil, "nothing to paste isn't an error")
        platform.content = .text("from another app\r\n", url: nil)
        #expect(value(string()) == "from another app\r\n", "as it is")
        #expect(value(url()) == nil, "text that isn't said to be a URL isn't one")
        platform.content = .text("https://swift.org", url: nil)
        #expect(value(url()) == nil, "even when it looks like one")

        platform.content = .text("Swift", url: "https://swift.org")
        #expect(value(string()) == "Swift" && value(url()) == "https://swift.org")
        platform.content = .text("", url: "https://swift.org")
        #expect(value(string()) == "https://swift.org", "a URL's text when a URL is all there is")
        platform.content = .image(Self.png, type: .png)
        #expect(value(string()) == nil && value(url()) == nil)
        #expect(platform.reads == [.text, .text, .text, .url, .url, .text, .url, .text, .text, .url])
    }

    @Test func aRefusalIsNotAllowed() {
        platform.content = .text("secret", url: nil)
        platform.refusesReads = true
        #expect(error(string()) == .notAllowed && error(url()) == .notAllowed)
        #expect(error(image()) == .notAllowed && error(image(to: .caches / "pasted")) == .notAllowed)
        #expect(onDisk("Container/Caches/pasted") == nil)

        platform.writeError = .notAllowed
        #expect(copy { pasteboard.setString("x", completion: $0) } == .some(.notAllowed))
        #expect(copy { pasteboard.setImage(contentsOf: .bundle / "logo.png", completion: $0) } == .some(.notAllowed))
        pasteboard.setString("dropped")
        #expect(platform.content == .text("secret", url: nil), "a copy with no handler fails quietly")
    }

    @Test func aPlatformMayAskFirstAndIsHeardOnce() {
        platform.content = .text("after the alert", url: nil)
        platform.asksFirst = true
        platform.answersTwice = true
        var answers: [String?] = []
        pasteboard.string { answers.append(try? $0.get()) }
        #expect(answers.isEmpty && platform.waiting.count == 1, "waiting for the user")
        platform.waiting.removeFirst()()
        #expect(answers == ["after the alert"], "its second answer wasn't passed on")

        platform.asksFirst = false
        var copies = 0
        pasteboard.setString("twice") { _ in copies += 1 }
        #expect(copies == 1)
        var files = 0
        platform.content = .image(Self.png, type: .png)
        pasteboard.image(to: .caches / "once.png") { _ in files += 1 }
        #expect(files == 1)
    }

    @Test func whatIsTooLargeIsRefused() {
        HostClipboard.maximumSize = 10
        #expect(copy { pasteboard.setString("0123456789", completion: $0) } == Self.succeeded)
        #expect(copy { pasteboard.setString("0123456789a", completion: $0) } == .some(.tooLarge))
        #expect(copy { pasteboard.setURL("https://example.com/long", title: "x", completion: $0) } == .some(.tooLarge))
        #expect(copy { pasteboard.setImage(Self.png, type: .png, completion: $0) } == .some(.tooLarge))
        #expect(copy { pasteboard.setImage(contentsOf: .bundle / "logo.png", completion: $0) } == .some(.tooLarge))
        #expect(platform.content == .text("0123456789", url: nil))
        platform.content = .image(Self.png, type: .png)
        #expect(error(image()) == .tooLarge && error(image(to: .caches / "big.png")) == .tooLarge)
        #expect(onDisk("Container/Caches/big.png") == nil)
    }

    // MARK: Images

    @Test func anImageIsCopiedFromItsBytesOrItsFile() {
        #expect(copy { pasteboard.setImage(Self.png, type: .jpeg, completion: $0) } == Self.succeeded)
        #expect(platform.content == .image(Self.png, type: .png), "the bytes say what it is")
        #expect(copy { pasteboard.setImage(Array("GIF89a".utf8), type: .png, completion: $0) } == .some(.invalidData))
        #expect(copy { pasteboard.setImage([], type: .png, completion: $0) } == .some(.invalidData))

        #expect(copy { pasteboard.setImage(contentsOf: .documents / "photo.jpg", options: .sensitive, completion: $0) } == Self.succeeded)
        #expect(platform.content == .image(Self.jpeg, type: .jpeg) && platform.isSensitive)
        #expect(copy { pasteboard.setImage(contentsOf: .bundle / "logo.png", completion: $0) } == Self.succeeded)
        #expect(platform.content == .image(Self.png, type: .png))

        #expect(copy { pasteboard.setImage(contentsOf: .documents / "notes.txt", completion: $0) } == .some(.invalidData), "not an image")
        #expect(copy { pasteboard.setImage(contentsOf: .documents / "none.png", completion: $0) } == .some(.invalidData), "not there")
        #expect(copy { pasteboard.setImage(contentsOf: FilePath(.documents), completion: $0) } == .some(.invalidData), "a folder")
        #expect(copy { pasteboard.setImage(contentsOf: .documents / "../Home/x.png", completion: $0) } == .some(.invalidData))
        #expect(platform.content == .image(Self.png, type: .png), "none of those replaced it")
    }

    @Test func aPickedDocumentIsCopiedAndPastedInto() throws {
        try Data(Self.jpeg).write(to: root.appendingPathComponent("Home/picked.jpg"))
        let granted = HostFiles.grant(HostFiles.Grant(path: root.appendingPathComponent("Home/picked.jpg").path, kind: .file, isWritable: true))
        #expect(copy { pasteboard.setImage(contentsOf: FilePath(granted), completion: $0) } == Self.succeeded)
        #expect(platform.content == .image(Self.jpeg, type: .jpeg))

        platform.content = .image(Self.png, type: .png)
        #expect(value(image(to: FilePath(granted))) == .png)
        #expect(onDisk("Home/picked.jpg") == Self.png, "the user's file now holds what was pasted")

        HostFiles.revoke(granted)
        #expect(copy { pasteboard.setImage(contentsOf: FilePath(granted), completion: $0) } == .some(.notAllowed), "a document the app no longer holds")
        #expect(error(image(to: FilePath(granted))) == .notAllowed)
    }

    @Test func anImageIsPastedAsBytesOrIntoAFile() {
        #expect(value(image()) == nil && error(image()) == nil)
        #expect(value(image(to: .caches / "pasted")) == nil && error(image(to: .caches / "pasted")) == nil)
        #expect(onDisk("Container/Caches/pasted") == nil, "no image, and no file")

        platform.content = .image(Self.jpeg, type: .jpeg)
        #expect(value(image()) == PasteboardImage(data: Self.jpeg, type: .jpeg))
        #expect(value(image(to: .caches / "in/a/folder/pasted")) == .jpeg)
        #expect(onDisk("Container/Caches/in/a/folder/pasted") == Self.jpeg, "the folders above it are made")
        platform.content = .image(Self.png, type: .jpeg)
        #expect(value(image(to: .caches / "in/a/folder/pasted")) == .png, "the bytes say what it is")
        #expect(onDisk("Container/Caches/in/a/folder/pasted") == Self.png, "replacing what was there")

        #expect(error(image(to: .bundle / "logo.png")) == .notAllowed, "the bundle is read-only")
        #expect(onDisk("App/resources/logo.png") == Self.png)
        #expect(error(image(to: .caches / "../Home/out.png")) == .invalidData)
        #expect(error(image(to: FilePath(.caches))) == .invalidData, "a folder")

        // A platform must convert what isn't one of the two.
        platform.content = .image(Array("II*\0 a TIFF".utf8), type: .png)
        #expect(error(image()) == .invalidData && error(image(to: .caches / "tiff")) == .invalidData)
        #expect(onDisk("Container/Caches/tiff") == nil)
        platform.content = .text("words", url: nil)
        #expect(value(image()) == nil && error(image()) == nil)
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func callsCanBeAwaited() async throws {
        HostClipboard.work = { job in DispatchQueue.global().async(execute: job) }
        HostClipboard.deliver = { DispatchQueue.main.async(execute: $0) }
        try await pasteboard.setString("awaited")
        #expect(try await pasteboard.string() == "awaited")
        #expect(try await pasteboard.url() == nil)
        try await pasteboard.setURL("https://swift.org", title: "Swift")
        #expect(try await pasteboard.url() == "https://swift.org")
        try await pasteboard.setImage(contentsOf: .bundle / "logo.png")
        #expect(try await pasteboard.image() == PasteboardImage(data: Self.png, type: .png))
        #expect(try await pasteboard.image(to: .caches / "awaited.png") == .png)
        #expect(onDisk("Container/Caches/awaited.png") == Self.png)
        try await pasteboard.setImage(Self.jpeg, type: .jpeg)
        try await pasteboard.clear()
        #expect(try await pasteboard.image() == nil)

        platform.refusesReads = true
        do {
            _ = try await pasteboard.string()
            Issue.record("a refused paste gave something")
        } catch {
            #expect(error == .notAllowed)
        }
    }
}
