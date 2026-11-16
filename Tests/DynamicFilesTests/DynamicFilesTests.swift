import Testing
import DynamicFiles
import DynamicRuntime
import RuntimeNative

/// A host's files that only write down what they're asked, and keep each
/// callback for the test to answer.
final class ScriptedFiles: Files {

    nonisolated(unsafe) static var instance = ScriptedFiles()

    var calls: [String] = []

    var callbacks: [any FileCallback] = []

    static func shared() -> ScriptedFiles { instance }

    /// The callback of the operation issued `back` operations ago.
    func callback(_ back: Int = 0) -> any FileCallback {
        callbacks[callbacks.count - 1 - back]
    }

    func read(_ directory: Int32, path: String, offset: Int64, length: Int64, callback: any FileCallback) {
        calls.append("read \(directory) \(path) \(offset) \(length)")
        callbacks.append(callback)
    }

    func write(_ directory: Int32, path: String, data: [UInt8], mode: Int32, callback: any FileCallback) {
        calls.append("write \(directory) \(path) \(data) \(mode)")
        callbacks.append(callback)
    }

    func list(_ directory: Int32, path: String, callback: any FileCallback) {
        calls.append("list \(directory) \(path)")
        callbacks.append(callback)
    }

    func attributes(_ directory: Int32, path: String, callback: any FileCallback) {
        calls.append("attributes \(directory) \(path)")
        callbacks.append(callback)
    }

    func makeDirectory(_ directory: Int32, path: String, callback: any FileCallback) {
        calls.append("makeDirectory \(directory) \(path)")
        callbacks.append(callback)
    }

    func remove(_ directory: Int32, path: String, callback: any FileCallback) {
        calls.append("remove \(directory) \(path)")
        callbacks.append(callback)
    }

    func move(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        calls.append("move \(directory) \(path) \(toDirectory) \(toPath)")
        callbacks.append(callback)
    }

    func copy(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        calls.append("copy \(directory) \(path) \(toDirectory) \(toPath)")
        callbacks.append(callback)
    }
}

/// Serialized: the tests share the native runtime and the scripted host.
@Suite(.serialized) struct DynamicFilesTests {

    let host: ScriptedFiles

    let files: DynamicFiles.FileManager

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        FilesProxy.register(ScriptedFiles.self, in: native)
        FileCallbackProxy.registerInterface(in: native)
        host = ScriptedFiles()
        ScriptedFiles.instance = host
        files = DynamicFiles.FileManager()
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    // MARK: Contracts

    @Test func filesNeedNoCapability() {
        let files = FilesProxy.descriptor
        #expect(files.name == "org.pureswift.files.Files")
        #expect(files.capability == nil)
        #expect(method(files, "shared")?.kind == .constructor)
        #expect(method(files, "read:path:offset:length:callback:")?.signature == Signature("(IOJJO)V"))
        #expect(method(files, "write:path:data:mode:callback:")?.signature == Signature("(IOOIO)V"))
        #expect(method(files, "list:path:callback:")?.signature == Signature("(IOO)V"))
        #expect(method(files, "attributes:path:callback:")?.signature == Signature("(IOO)V"))
        #expect(method(files, "move:path:toDirectory:toPath:callback:")?.signature == Signature("(IOIOO)V"))
        #expect(files.methods.count == 9)
    }

    @Test func callbackCarriesOneAnswer() {
        let callback = FileCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.files.FileCallback")
        #expect(callback.kind == .callback)
        #expect(method(callback, "didComplete")?.signature == Signature("()V"))
        #expect(method(callback, "didRead:")?.signature == Signature("(O)V"))
        #expect(method(callback, "didList:")?.signature == Signature("(O)V"))
        #expect(method(callback, "didGetAttributes:size:modified:")?.signature == Signature("(IJJ)V"))
        #expect(method(callback, "didFail:")?.signature == Signature("(I)V"))
        let descriptors = [FilesProxy.descriptor, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Paths

    @Test func pathsAreADirectoryAndComponents() {
        let save: FilePath = .documents / "saves/slot1.sav"
        #expect(save.directory == .documents)
        #expect(save.path == "saves/slot1.sav")
        #expect(save.components == ["saves", "slot1.sav"])
        #expect(save.lastComponent == "slot1.sav")
        #expect(save.deletingLastComponent == .documents / "saves")
        #expect(save.deletingLastComponent.deletingLastComponent == FilePath(.documents))
        #expect(FilePath(.documents).deletingLastComponent == FilePath(.documents), "nothing above the directory")
        #expect(FilePath(.caches).appending("a") / "b" == .caches / "a/b")
        #expect(FilePath(.caches).components.isEmpty && FilePath(.caches).lastComponent == "")
        // A listing's "saves/" can be used as it is.
        #expect((.documents / "saves/") == (.documents / "saves"))
        #expect(FileDirectory.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
    }

    @Test func invalidPathsAreKnownBeforehand() {
        #expect((.data / "a/b.txt").isValid)
        #expect(FilePath(.data).isValid, "the directory itself")
        #expect(!(.data / "../other").isValid)
        #expect(!(.data / "a/./b").isValid)
        #expect(!(.data / "/absolute").isValid)
        #expect(!(.data / "a//b").isValid)
        #expect(!(.data / "nul\0byte").isValid)
    }

    // MARK: FileManager

    @Test func everyCallNamesItsDirectoryAndPath() {
        let ignore: (Result<Void, FileError>) -> Void = { _ in }
        files.contents(at: .bundle / "levels/1.map") { _ in }
        files.contents(at: .caches / "big.bin", offset: 4096, length: 512) { _ in }
        files.write([1, 2], to: .documents / "a.bin", completion: ignore)
        files.append([3], to: .documents / "a.bin", completion: ignore)
        files.contentsOfDirectory(at: FilePath(.documents)) { _ in }
        files.attributesOfItem(at: .data / "db") { _ in }
        files.createDirectory(at: .data / "x/y", completion: ignore)
        files.removeItem(at: .temporary / "t", completion: ignore)
        files.moveItem(at: .temporary / "t", to: .documents / "kept", completion: ignore)
        files.copyItem(at: .bundle / "seed.db", to: .data / "db", completion: ignore)
        #expect(host.calls == [
            "read 4 levels/1.map 0 -1",
            "read 2 big.bin 4096 512",
            "write 0 a.bin [1, 2] 0",
            "write 0 a.bin [3] 1",
            "list 0 ",
            "attributes 1 db",
            "makeDirectory 1 x/y",
            "remove 3 t",
            "move 3 t 0 kept",
            "copy 4 seed.db 1 db",
        ])
    }

    @Test func answersBecomeResults() {
        var data: Result<[UInt8], FileError>?
        files.contents(at: .documents / "a") { data = $0 }
        #expect(data == nil, "not until the host answers")
        host.callback().didRead([9, 8, 7])
        #expect(data == .success([9, 8, 7]))

        var names: Result<[String], FileError>?
        files.contentsOfDirectory(at: FilePath(.documents)) { names = $0 }
        host.callback().didList(["a", "saves/"])
        #expect(names == .success(["a", "saves/"]))

        var attributes: Result<FileAttributes, FileError>?
        files.attributesOfItem(at: .documents / "a") { attributes = $0 }
        host.callback().didGetAttributes(kind: 0, size: 3, modified: 1_700_000_000_000)
        #expect(attributes == .success(FileAttributes(kind: .file, size: 3, modified: 1_700_000_000_000)))

        files.attributesOfItem(at: .bundle / "assets") { attributes = $0 }
        host.callback().didGetAttributes(kind: 1, size: 0, modified: 0)
        #expect(attributes == .success(FileAttributes(kind: .directory, size: 0, modified: nil)), "0: the host doesn't know")
        #expect(try! attributes!.get().isDirectory)

        var written = false
        files.write([1], to: .documents / "a") { if case .success = $0 { written = true } }
        host.callback().didComplete()
        #expect(written)
    }

    @Test func failuresAndStrayAnswers() {
        var data: Result<[UInt8], FileError>?
        files.contents(at: .documents / "missing") { data = $0 }
        host.callback().didFail(FileError.notFound.rawValue)
        #expect(data == .failure(.notFound))

        // A code from a newer host.
        files.contents(at: .documents / "x") { data = $0 }
        host.callback().didFail(999)
        #expect(data == .failure(.unknown))

        // An answer of the wrong kind is a failure, not a crash.
        files.contents(at: .documents / "x") { data = $0 }
        host.callback().didComplete()
        #expect(data == .failure(.unknown))

        // Only the first answer counts.
        var answers = 0
        files.contents(at: .documents / "x") { _ in answers += 1 }
        host.callback().didRead([1])
        host.callback().didFail(FileError.notFound.rawValue)
        host.callback().didRead([2])
        #expect(answers == 1)
    }

    @Test func existenceIsAttributesWithoutTheError() {
        var exists: Result<Bool, FileError>?
        files.fileExists(at: .caches / "thumb.png") { exists = $0 }
        #expect(host.calls == ["attributes 2 thumb.png"])
        host.callback().didGetAttributes(kind: 0, size: 10, modified: 5)
        #expect(exists == .success(true))

        files.fileExists(at: .caches / "gone.png") { exists = $0 }
        host.callback().didFail(FileError.notFound.rawValue)
        #expect(exists == .success(false))

        files.fileExists(at: .caches / "../x") { exists = $0 }
        host.callback().didFail(FileError.invalidPath.rawValue)
        #expect(exists == .failure(.invalidPath), "other failures stay failures")
    }

    @Test func answersCanArriveOutOfOrder() {
        var first: Result<[UInt8], FileError>?, second: Result<[UInt8], FileError>?
        files.contents(at: .documents / "one") { first = $0 }
        files.contents(at: .documents / "two") { second = $0 }
        host.callback(0).didRead([2])
        #expect(first == nil && second == .success([2]), "each answer goes to the call that asked")
        host.callback(1).didRead([1])
        #expect(first == .success([1]))
    }

    // The async tests run on the main actor, with their child tasks: the
    // runtime is single-threaded (§6.4), and a host answers on the thread
    // the guest runs on.

    @MainActor @Test func callsCanBeAwaited() async throws {
        let files = self.files
        let host = self.host
        let reading = Task { @MainActor in
            try await files.contents(at: .documents / "note.txt")
        }
        // The call is issued once the child task runs.
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        host.callback().didRead(Array("hello".utf8))
        #expect(try await reading.value == Array("hello".utf8))

        let missing = Task { @MainActor in
            try await files.attributesOfItem(at: .documents / "none")
        }
        while host.callbacks.count < 2 {
            await Task.yield()
        }
        host.callback().didFail(FileError.notFound.rawValue)
        var failure: FileError?
        do {
            _ = try await missing.value
        } catch {
            failure = error as? FileError
        }
        #expect(failure == .notFound)
    }

    @MainActor @Test func aCancelledTaskStopsWaiting() async {
        let files = self.files
        let host = self.host
        let task = Task { @MainActor in
            try await files.contents(at: .documents / "slow")
        }
        while host.callbacks.isEmpty {
            await Task.yield()
        }
        task.cancel()
        var failure: FileError?
        do {
            _ = try await task.value
        } catch {
            failure = error as? FileError
        }
        #expect(failure == .cancelled)
        // The host's late answer has nowhere to go, and nothing breaks.
        host.callback().didRead([1])
    }
}
