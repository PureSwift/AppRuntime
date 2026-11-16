import Foundation
import Testing
import DynamicFiles
import DynamicRuntime
import RuntimeNative
@testable import RuntimeHost

/// `HostFiles` against real files in a temporary directory: the file
/// system directly, and then through the runtime from the guest's
/// `FileManager`.
///
/// Serialized: `HostFiles.configure` and the native runtime are shared.
@Suite(.serialized) final class HostFilesTests {

    let root: URL

    let directories: [FileDirectory: String]

    let system: FileSystem

    static let documents = FileDirectory.documents.rawValue
    static let caches = FileDirectory.caches.rawValue
    static let temporary = FileDirectory.temporary.rawValue
    static let bundle = FileDirectory.bundle.rawValue

    init() throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("HostFilesTests-\(UUID().uuidString)")
        directories = [
            .documents: root.appendingPathComponent("Documents").path,
            .data: root.appendingPathComponent("Data").path,
            .caches: root.appendingPathComponent("Caches").path,
            .temporary: root.appendingPathComponent("tmp").path,
            .bundle: root.appendingPathComponent("App/resources").path,
        ]
        // The bundle is the packager's, made before the app runs.
        let levels = root.appendingPathComponent("App/resources/levels")
        try manager.createDirectory(at: levels, withIntermediateDirectories: true)
        try Data("LEVEL ONE".utf8).write(to: levels.appendingPathComponent("1.map"))
        system = FileSystem(directories: directories, maximumTransfer: 1024)
        try system.prepare()
    }

    deinit {
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    /// What the file system itself has at a path under the root.
    func onDisk(_ path: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
    }

    /// What `body` failed with; `nil` when it didn't.
    func failure(_ body: () throws -> Void) -> FileError? {
        do {
            try body()
            return nil
        } catch {
            return error as? FileError
        }
    }

    // MARK: The file system

    @Test func prepareMakesTheWritableDirectories() {
        for name in ["Documents", "Data", "Caches", "tmp"] {
            var isDirectory: ObjCBool = false
            #expect(Foundation.FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func writesReplaceWholeFilesAndMakeDirectories() throws {
        try system.write(Self.documents, "saves/a/slot1.sav", data: Array("first version".utf8), mode: 0)
        #expect(onDisk("Documents/saves/a/slot1.sav") == Data("first version".utf8))
        try system.write(Self.documents, "saves/a/slot1.sav", data: Array("2nd".utf8), mode: 0)
        #expect(onDisk("Documents/saves/a/slot1.sav") == Data("2nd".utf8), "nothing of the old file is left")
        #expect(try system.list(Self.documents, "saves/a") == ["slot1.sav"], "no temporary file stays behind")

        try system.write(Self.documents, "empty", data: [], mode: 0)
        #expect(try system.read(Self.documents, "empty", offset: 0, length: -1) == [])
        #expect(failure { try system.write(Self.documents, "saves", data: [1], mode: 0) } == .isDirectory)
        #expect(failure { try system.write(Self.documents, "", data: [1], mode: 0) } == .isDirectory)
        #expect(failure { try system.write(Self.documents, "empty/under", data: [1], mode: 0) } == .notDirectory)
        #expect(failure { try system.write(Self.documents, "x", data: [1], mode: 7) } == .unknown)
    }

    @Test func appendsAddAndCreate() throws {
        try system.write(Self.caches, "log/today.txt", data: Array("one\n".utf8), mode: 1)
        try system.write(Self.caches, "log/today.txt", data: Array("two\n".utf8), mode: 1)
        #expect(onDisk("Caches/log/today.txt") == Data("one\ntwo\n".utf8))
    }

    @Test func readsWholeFilesAndRanges() throws {
        try system.write(Self.documents, "abc", data: Array("0123456789".utf8), mode: 0)
        func read(_ offset: Int64, _ length: Int64) throws(FileError) -> String {
            String(decoding: try system.read(Self.documents, "abc", offset: offset, length: length), as: UTF8.self)
        }
        #expect(try read(0, -1) == "0123456789")
        #expect(try read(3, 4) == "3456")
        #expect(try read(7, -1) == "789")
        #expect(try read(8, 100) == "89", "less, past the end")
        #expect(try read(10, 5) == "" && read(500, -1) == "")
        #expect(failure { _ = try system.read(Self.documents, "abc", offset: -1, length: 1) } == .unknown)
        #expect(failure { _ = try system.read(Self.documents, "none", offset: 0, length: -1) } == .notFound)
        #expect(failure { _ = try system.read(Self.documents, "", offset: 0, length: -1) } == .isDirectory)
    }

    @Test func transfersOverTheLimitAreTooLarge() throws {
        let block = [UInt8](repeating: 7, count: 1024)
        #expect(failure { try system.write(Self.caches, "big", data: block + [1], mode: 0) } == .tooLarge)
        // Larger files are written and read in pieces.
        try system.write(Self.caches, "big", data: block, mode: 0)
        try system.write(Self.caches, "big", data: block, mode: 1)
        #expect(try system.attributes(Self.caches, "big").size == 2048)
        #expect(failure { _ = try system.read(Self.caches, "big", offset: 0, length: -1) } == .tooLarge)
        #expect(try system.read(Self.caches, "big", offset: 1024, length: 1024) == block)
    }

    @Test func listsAreSortedWithDirectoriesMarked() throws {
        #expect(try system.list(Self.documents, "") == [])
        // Names that differ by more than case: on a Mac's usual volume
        // "b" and "B" are one file.
        for name in ["b.txt", "C.txt", "a.txt", "é.txt"] {
            try system.write(Self.documents, "mix/\(name)", data: [1], mode: 0)
        }
        try system.makeDirectory(Self.documents, "mix/folder")
        // By bytes: capitals, then lower case, then anything past ASCII.
        #expect(try system.list(Self.documents, "mix") == ["C.txt", "a.txt", "b.txt", "folder/", "é.txt"])
        #expect(try system.list(Self.documents, "") == ["mix/"])
        #expect(failure { _ = try system.list(Self.documents, "mix/a.txt") } == .notDirectory)
        #expect(failure { _ = try system.list(Self.documents, "none") } == .notFound)
    }

    @Test func namesThatDifferByCaseMayBeOneFile() throws {
        try system.write(Self.documents, "case/Name.txt", data: Array("first".utf8), mode: 0)
        try system.write(Self.documents, "case/name.txt", data: Array("second".utf8), mode: 0)
        // One file on a Mac's usual volume, two on Linux: either way the
        // last write is what "name.txt" reads, and listing works.
        let names = try system.list(Self.documents, "case")
        #expect(names.count == 1 || names == ["Name.txt", "name.txt"])
        #expect(try system.read(Self.documents, "case/name.txt", offset: 0, length: -1) == Array("second".utf8))
    }

    @Test func attributesTellFilesFromDirectories() throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000) - 2000
        try system.write(Self.documents, "note.txt", data: Array("hello".utf8), mode: 0)
        let file = try system.attributes(Self.documents, "note.txt")
        #expect(file.kind == .file && file.size == 5)
        let modified = try #require(file.modified)
        #expect(modified >= before && modified <= before + 10_000, "milliseconds since 1970")

        try system.makeDirectory(Self.documents, "folder")
        #expect(try system.attributes(Self.documents, "folder") .kind == .directory)
        #expect(try system.attributes(Self.documents, "folder").size == 0)
        #expect(try system.attributes(Self.documents, "").isDirectory, "the directory itself")
        #expect(failure { _ = try system.attributes(Self.documents, "none") } == .notFound)
        #expect(failure { _ = try system.attributes(Self.documents, "note.txt/under") } == .notFound)
    }

    @Test func directoriesAreMadeWithThoseAboveThem() throws {
        try system.makeDirectory(Self.documents, "a/b/c")
        #expect(try system.list(Self.documents, "a/b") == ["c/"])
        try system.makeDirectory(Self.documents, "a/b/c")
        try system.write(Self.documents, "file", data: [1], mode: 0)
        #expect(failure { try system.makeDirectory(Self.documents, "file") } == .alreadyExists)
        #expect(failure { try system.makeDirectory(Self.documents, "file/under/it") } == .notDirectory)
    }

    @Test func removingTakesTreesAndForgivesWhatsGone() throws {
        try system.write(Self.caches, "thumbs/1/a.png", data: [1], mode: 0)
        try system.write(Self.caches, "thumbs/2/b.png", data: [2], mode: 0)
        try system.write(Self.caches, "keep.txt", data: [3], mode: 0)
        try system.remove(Self.caches, "thumbs/1/a.png")
        #expect(try system.list(Self.caches, "thumbs/1") == [])
        try system.remove(Self.caches, "thumbs")
        #expect(try system.list(Self.caches, "") == ["keep.txt"])
        try system.remove(Self.caches, "thumbs")
        try system.remove(Self.caches, "never/was")

        // The empty path empties the directory, which stays.
        try system.remove(Self.caches, "")
        #expect(try system.list(Self.caches, "") == [])
        #expect(try system.attributes(Self.caches, "").isDirectory)
    }

    @Test func movesAndCopiesNeedAFreeDestination() throws {
        try system.write(Self.temporary, "download.part", data: Array("payload".utf8), mode: 0)
        try system.move(Self.temporary, "download.part", to: Self.documents, "files/done.bin")
        #expect(onDisk("Documents/files/done.bin") == Data("payload".utf8))
        #expect(failure { _ = try system.attributes(Self.temporary, "download.part") } == .notFound)

        try system.copy(Self.documents, "files", to: Self.caches, "mirror/files")
        #expect(onDisk("Caches/mirror/files/done.bin") == Data("payload".utf8))
        #expect(onDisk("Documents/files/done.bin") != nil, "a copy leaves the original")

        #expect(failure { try system.copy(Self.documents, "files", to: Self.caches, "mirror/files") } == .alreadyExists)
        #expect(failure { try system.move(Self.documents, "files/done.bin", to: Self.caches, "mirror/files/done.bin") } == .alreadyExists)
        #expect(failure { try system.move(Self.documents, "none", to: Self.caches, "x") } == .notFound)
        #expect(failure { try system.copy(Self.documents, "files", to: Self.documents, "files/inside") } == .invalidPath, "into itself")
        #expect(failure { try system.move(Self.documents, "", to: Self.caches, "all") } == .invalidPath, "a directory itself")
        #expect(failure { try system.copy(Self.documents, "files", to: Self.caches, "") } == .invalidPath)
    }

    @Test func theBundleIsReadOnly() throws {
        #expect(try system.read(Self.bundle, "levels/1.map", offset: 0, length: -1) == Array("LEVEL ONE".utf8))
        #expect(try system.list(Self.bundle, "") == ["levels/"])
        #expect(failure { try system.write(Self.bundle, "levels/2.map", data: [1], mode: 0) } == .readOnly)
        #expect(failure { try system.remove(Self.bundle, "levels/1.map") } == .readOnly)
        #expect(failure { try system.makeDirectory(Self.bundle, "more") } == .readOnly)
        #expect(failure { try system.move(Self.bundle, "levels/1.map", to: Self.documents, "1.map") } == .readOnly)
        #expect(failure { try system.copy(Self.documents, "x", to: Self.bundle, "x") } == .readOnly)
        // Copying out is how an app seeds its data.
        try system.copy(Self.bundle, "levels", to: Self.documents, "levels")
        #expect(onDisk("Documents/levels/1.map") == Data("LEVEL ONE".utf8))
        #expect(onDisk("App/resources/levels/1.map") != nil)
    }

    @Test func pathsStayInsideTheirDirectory() throws {
        for path in ["../Data/x", "a/../../x", "/etc/passwd", "a//b", "a/./b", "a/", "nul\0byte"] {
            #expect(failure { _ = try system.read(Self.documents, path, offset: 0, length: -1) } == .invalidPath, "\(path.debugDescription)")
            #expect(failure { try system.write(Self.documents, path, data: [1], mode: 0) } == .invalidPath)
        }
        #expect(failure { _ = try system.list(99, "") } == .invalidPath, "no such directory")
        let partial = FileSystem(directories: [.documents: directories[.documents]!], maximumTransfer: 1024)
        #expect(failure { _ = try partial.list(Self.caches, "") } == .notFound, "one this host has no place for")
        #expect(onDisk("Data/x") == nil)
    }

    @Test func linksOutOfADirectoryArentFollowed() throws {
        let manager = Foundation.FileManager.default
        let outside = root.appendingPathComponent("Outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let documents = root.appendingPathComponent("Documents")
        try manager.createSymbolicLink(at: documents.appendingPathComponent("out"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: documents.appendingPathComponent("secret-link"), withDestinationURL: outside.appendingPathComponent("secret.txt"))

        #expect(failure { _ = try system.read(Self.documents, "out/secret.txt", offset: 0, length: -1) } == .invalidPath)
        #expect(failure { _ = try system.read(Self.documents, "secret-link", offset: 0, length: -1) } == .invalidPath)
        #expect(failure { _ = try system.list(Self.documents, "out") } == .invalidPath)
        #expect(failure { try system.write(Self.documents, "out/planted.txt", data: [1], mode: 0) } == .invalidPath)
        #expect(failure { try system.remove(Self.documents, "out/secret.txt") } == .invalidPath)
        #expect(manager.fileExists(atPath: outside.appendingPathComponent("secret.txt").path))
        #expect(!manager.fileExists(atPath: outside.appendingPathComponent("planted.txt").path))

        // A link that stays inside is only another name.
        try system.write(Self.documents, "real/note.txt", data: Array("inside".utf8), mode: 0)
        try manager.createSymbolicLink(at: documents.appendingPathComponent("alias"), withDestinationURL: documents.appendingPathComponent("real"))
        #expect(try system.read(Self.documents, "alias/note.txt", offset: 0, length: -1) == Array("inside".utf8))
    }

    @Test func temporaryIsEmptiedAtStart() throws {
        try system.write(Self.temporary, "left/over.tmp", data: [1], mode: 0)
        try system.write(Self.documents, "kept.txt", data: [1], mode: 0)
        // The app starts again.
        try FileSystem(directories: directories, maximumTransfer: 1024).prepare()
        #expect(try system.list(Self.temporary, "") == [])
        #expect(try system.list(Self.documents, "") == ["kept.txt"])
    }

    // MARK: Through the runtime

    /// The guest's `FileManager` over the contract, with the host doing its
    /// work at once so a test can read the result on the next line.
    func guestFiles() throws -> DynamicFiles.FileManager {
        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: directories, work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        return DynamicFiles.FileManager()
    }

    @Test func moduleListsItsContracts() {
        #expect(HostFilesModule.contracts.map(\.name) == ["org.pureswift.files.Files", "org.pureswift.files.FileCallback"])
        #expect(HostFilesModule.isUsed(by: ["org.pureswift.files.Files"]))
        #expect(!HostFilesModule.isUsed(by: ["org.pureswift.ui.Renderer"]))
    }

    @Test func aGuestReadsAndWritesRealFiles() throws {
        let files = try guestFiles()
        var written: Result<Void, FileError>?
        files.write(Array("saved by the guest".utf8), to: .documents / "saves/slot1.sav") { written = $0 }
        #expect((try? written?.get()) != nil)
        #expect(onDisk("Documents/saves/slot1.sav") == Data("saved by the guest".utf8))

        var level: Result<[UInt8], FileError>?
        files.contents(at: .bundle / "levels/1.map") { level = $0 }
        #expect(level == .success(Array("LEVEL ONE".utf8)))

        var part: Result<[UInt8], FileError>?
        files.contents(at: .bundle / "levels/1.map", offset: 6, length: nil) { part = $0 }
        #expect(part == .success(Array("ONE".utf8)))

        var names: Result<[String], FileError>?
        files.contentsOfDirectory(at: FilePath(.documents)) { names = $0 }
        #expect(names == .success(["saves/"]))

        var attributes: Result<FileAttributes, FileError>?
        files.attributesOfItem(at: .documents / "saves/slot1.sav") { attributes = $0 }
        #expect(try attributes?.get().size == 18)
        #expect(try attributes?.get().modified != nil)

        var exists: Result<Bool, FileError>?
        files.fileExists(at: .documents / "saves/none") { exists = $0 }
        #expect(exists == .success(false))

        var refused: Result<Void, FileError>?
        files.write([1], to: .bundle / "levels/2.map") { refused = $0 }
        #expect(throws: FileError.readOnly) { try refused?.get() }
        files.removeItem(at: .documents / "../Data") { refused = $0 }
        #expect(throws: FileError.invalidPath) { try refused?.get() }

        var copied: Result<Void, FileError>?
        files.copyItem(at: .bundle / "levels", to: .data / "levels") { copied = $0 }
        #expect((try? copied?.get()) != nil)
        files.moveItem(at: .data / "levels/1.map", to: .caches / "moved.map") { copied = $0 }
        files.removeItem(at: .data / "levels") { copied = $0 }
        #expect(onDisk("Caches/moved.map") == Data("LEVEL ONE".utf8))
        #expect(onDisk("Data/levels/1.map") == nil)
        #expect(NativeRuntime.shared.runtime.handleCount <= 1, "nothing but the host's files object is left")
    }

    /// The configuration a host uses: work on the serial queue, answers on
    /// the main dispatch queue. The test is on the main actor, so the
    /// guest's calls and the host's answers share a thread, as they do in a
    /// host; the runtime is single-threaded (§6.4).
    @MainActor @Test func aGuestAwaitsTheHostsQueue() async throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: directories))
        HostFilesModule.register(in: native)
        let files = DynamicFiles.FileManager()

        try await files.write(Array("first".utf8), to: .documents / "order.txt")
        try await files.append(Array(", second".utf8), to: .documents / "order.txt")
        let contents = try await files.contents(at: .documents / "order.txt")
        #expect(String(decoding: contents, as: UTF8.self) == "first, second")
        #expect(try await files.contentsOfDirectory(at: FilePath(.documents)) == ["order.txt"])
        #expect(try await files.fileExists(at: .documents / "order.txt"))
        try await files.createDirectory(at: .documents / "folder")
        try await files.moveItem(at: .documents / "order.txt", to: .documents / "folder/order.txt")
        #expect(try await files.attributesOfItem(at: .documents / "folder").isDirectory)
        try await files.removeItem(at: .documents / "folder")
        #expect(try await files.contentsOfDirectory(at: FilePath(.documents)) == [])
        do {
            _ = try await files.contents(at: .documents / "order.txt")
            Issue.record("the file was removed")
        } catch {
            #expect(error == .notFound)
        }
    }
}
