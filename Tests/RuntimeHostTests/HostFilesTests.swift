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

    // MARK: Grants

    /// The user's own files, outside the app's directories.
    func home() throws -> URL {
        let home = root.appendingPathComponent("Home").resolvingSymlinksInPath()
        try Foundation.FileManager.default.createDirectory(at: home.appendingPathComponent("Music/Albums"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: home.appendingPathComponent("notes.txt"))
        try Data("one".utf8).write(to: home.appendingPathComponent("Music/Albums/one.mp3"))
        return home
    }

    @Test func aGrantedFileIsItsDirectorysEmptyPath() throws {
        let home = try home()
        var system = self.system
        let file: Int32 = 300
        system.grants[file] = HostFiles.Grant(path: home.appendingPathComponent("notes.txt").path, kind: .file, isWritable: true)

        #expect(try system.read(file, "", offset: 0, length: -1) == Array("notes".utf8))
        #expect(try system.read(file, "", offset: 2, length: 2) == Array("te".utf8))
        #expect(try system.attributes(file, "") == FileAttributes(kind: .file, size: 5, modified: system.attributes(file, "").modified))
        try system.write(file, "", data: Array("new notes".utf8), mode: 0)
        try system.write(file, "", data: Array("!".utf8), mode: 1)
        #expect(onDisk("Home/notes.txt") == Data("new notes!".utf8))
        #expect(try Foundation.FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == ["Music", "notes.txt"],
                "no temporary file stays behind")

        // It has nothing under it, and it stays where it is.
        #expect(failure { _ = try system.read(file, "inside", offset: 0, length: -1) } == .notDirectory)
        #expect(failure { try system.write(file, "inside", data: [1], mode: 0) } == .notDirectory)
        #expect(failure { _ = try system.list(file, "") } == .notDirectory)
        #expect(failure { try system.remove(file, "") } == .invalidPath)
        #expect(failure { try system.move(file, "", to: Self.documents, "taken.txt") } == .invalidPath)
        #expect(failure { try system.copy(Self.documents, "x", to: file, "") } == .invalidPath)
        #expect(failure { _ = try system.read(file, "../notes.txt", offset: 0, length: -1) } == .invalidPath)
        #expect(onDisk("Home/notes.txt") == Data("new notes!".utf8))

        // A copy comes into the app's own directories.
        try system.copy(file, "", to: Self.caches, "imported/notes.txt")
        #expect(onDisk("Caches/imported/notes.txt") == Data("new notes!".utf8))
    }

    @Test func aGrantForReadingRefusesWrites() throws {
        let home = try home()
        var system = self.system
        system.grants[301] = HostFiles.Grant(path: home.appendingPathComponent("notes.txt").path, kind: .file, isWritable: false)
        system.grants[302] = HostFiles.Grant(path: home.appendingPathComponent("Music").path, kind: .directory, isWritable: false)
        #expect(try system.read(301, "", offset: 0, length: -1) == Array("notes".utf8))
        #expect(failure { try system.write(301, "", data: [1], mode: 0) } == .readOnly)
        #expect(failure { try system.write(302, "new.mp3", data: [1], mode: 0) } == .readOnly)
        #expect(failure { try system.makeDirectory(302, "New") } == .readOnly)
        #expect(failure { try system.remove(302, "Albums") } == .readOnly)
        #expect(failure { try system.move(302, "Albums/one.mp3", to: Self.caches, "one.mp3") } == .readOnly)
        try system.copy(302, "Albums", to: Self.caches, "Albums")
        #expect(onDisk("Caches/Albums/one.mp3") == Data("one".utf8))
        #expect(onDisk("Home/notes.txt") == Data("notes".utf8))
    }

    @Test func aGrantedFolderIsADirectory() throws {
        let home = try home()
        var system = self.system
        let folder: Int32 = 303
        system.grants[folder] = HostFiles.Grant(path: home.appendingPathComponent("Music").path, kind: .directory, isWritable: true)

        #expect(try system.list(folder, "") == ["Albums/"])
        #expect(try system.read(folder, "Albums/one.mp3", offset: 0, length: -1) == Array("one".utf8))
        try system.write(folder, "New/two.mp3", data: Array("two".utf8), mode: 0)
        #expect(onDisk("Home/Music/New/two.mp3") == Data("two".utf8))
        try system.move(folder, "New/two.mp3", to: folder, "Albums/two.mp3")
        try system.remove(folder, "New")
        #expect(try system.list(folder, "") == ["Albums/"])
        #expect(try system.list(folder, "Albums") == ["one.mp3", "two.mp3"])
        #expect(try system.attributes(folder, "").isDirectory)

        // The folder itself stays, and nothing outside it is reached.
        #expect(failure { try system.remove(folder, "") } == .invalidPath)
        #expect(failure { try system.write(folder, "", data: [1], mode: 0) } == .isDirectory)
        #expect(failure { _ = try system.read(folder, "../notes.txt", offset: 0, length: -1) } == .invalidPath)
        try Foundation.FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent("Music/out").path, withDestinationPath: home.path)
        #expect(failure { _ = try system.read(folder, "out/notes.txt", offset: 0, length: -1) } == .invalidPath)

        // The whole of it can be copied in.
        try system.copy(folder, "", to: Self.documents, "Music")
        #expect(onDisk("Documents/Music/Albums/two.mp3") == Data("two".utf8))
    }

    @Test func aDirectoryNobodyGrantedIsNotPermitted() throws {
        #expect(failure { _ = try system.read(256, "", offset: 0, length: -1) } == .notPermitted)
        #expect(failure { try system.write(9999, "a", data: [1], mode: 0) } == .notPermitted)
        #expect(failure { _ = try system.read(5, "a", offset: 0, length: -1) } == .invalidPath, "not a directory at all")
        #expect(failure { _ = try system.read(255, "a", offset: 0, length: -1) } == .invalidPath)
        #expect(failure { _ = try system.read(-1, "a", offset: 0, length: -1) } == .invalidPath)
    }

    @Test func aFileAloneInAFolderTheAppCantWriteIsWrittenInPlace() throws {
        let home = try home()
        let locked = home.appendingPathComponent("Locked")
        let manager = Foundation.FileManager.default
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: locked.appendingPathComponent("only.txt"))
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var system = self.system
        system.grants[304] = HostFiles.Grant(path: locked.appendingPathComponent("only.txt").path, kind: .file, isWritable: true)
        try system.write(304, "", data: Array("new".utf8), mode: 0)
        #expect(onDisk("Home/Locked/only.txt") == Data("new".utf8))
    }

    @Test func hostsGrantAndRevokeDirectories() throws {
        let home = try home()
        try HostFiles.configure(HostFiles.Configuration(directories: directories, work: { $0() }, deliver: { $0() }))
        let notes = home.appendingPathComponent("notes.txt").path
        let first = HostFiles.grant(HostFiles.Grant(path: notes, kind: .file, isWritable: false))
        let second = HostFiles.grant(HostFiles.Grant(path: home.appendingPathComponent("Music").path, kind: .directory, isWritable: true))
        #expect(first.isGrant && second.isGrant && first != second)
        #expect(second.rawValue > first.rawValue, "a value isn't used twice")
        #expect(HostFiles.grant(for: first)?.path == notes)

        // Where another contract finds a file it's given a directory and a path for.
        #expect(try HostFiles.path(of: first.rawValue, path: "") == notes)
        #expect(try HostFiles.path(of: second.rawValue, path: "Albums/one.mp3") == home.appendingPathComponent("Music/Albums/one.mp3").path)
        #expect(try HostFiles.path(of: Self.documents, path: "a/b") == directories[.documents]! + "/a/b")
        #expect(failure { _ = try HostFiles.path(of: first.rawValue, path: "", writing: true) } == .readOnly)

        // The grants outlive a change of the app's directories.
        try HostFiles.configure(HostFiles.Configuration(directories: directories, work: { $0() }, deliver: { $0() }))
        #expect(HostFiles.grant(for: second) != nil)

        HostFiles.revoke(first)
        #expect(HostFiles.grant(for: first) == nil)
        #expect(failure { _ = try HostFiles.path(of: first.rawValue, path: "") } == .notPermitted)
        let third = HostFiles.grant(HostFiles.Grant(path: notes, kind: .file, isWritable: false))
        #expect(third.rawValue > second.rawValue)
        HostFiles.revoke(second)
        HostFiles.revoke(third)
    }

    @Test func aSnapshotReadsAndWritesAsFilesDo() throws {
        let home = try home()
        try HostFiles.configure(HostFiles.Configuration(directories: directories, work: { $0() }, deliver: { $0() }))
        let notes = home.appendingPathComponent("notes.txt").path
        let readOnly = HostFiles.grant(HostFiles.Grant(path: notes, kind: .file, isWritable: false))
        let music = HostFiles.grant(HostFiles.Grant(path: home.appendingPathComponent("Music").path, kind: .directory, isWritable: true))
        let snapshot = HostFiles.snapshot()

        // A picked document, one of the app's own files, and what isn't there.
        #expect(try snapshot.contents(readOnly.rawValue, path: "") == Array("notes".utf8))
        #expect(try snapshot.size(readOnly.rawValue, path: "") == 5)
        #expect(failure { try snapshot.write([1], to: readOnly.rawValue, path: "") } == .readOnly)
        try snapshot.write(Array("kept".utf8), to: Self.documents, path: "made/by/snapshot.txt")
        #expect(try snapshot.contents(Self.documents, path: "made/by/snapshot.txt") == Array("kept".utf8))
        #expect(try snapshot.size(Self.documents, path: "made/by/snapshot.txt") == 4)
        try snapshot.write(Array("song".utf8), to: music.rawValue, path: "one.mp3")
        #expect(onDisk("Home/Music/one.mp3") == Data("song".utf8))
        #expect(failure { _ = try snapshot.size(Self.documents, path: "made") } == .isDirectory)
        #expect(failure { _ = try snapshot.contents(Self.documents, path: "none.txt") } == .notFound)
        #expect(failure { _ = try snapshot.contents(Self.documents, path: "../Home/notes.txt") } == .invalidPath)

        // It has the grants there were when it was taken, as an operation
        // already issued does.
        HostFiles.revoke(readOnly)
        HostFiles.revoke(music)
        #expect(try snapshot.contents(readOnly.rawValue, path: "") == Array("notes".utf8))
        #expect(failure { _ = try HostFiles.snapshot().contents(readOnly.rawValue, path: "") } == .notPermitted)
    }

    @Test func aHostsOwnFilesAreReadCopiedAndReplaced() throws {
        let home = try home()
        let notes = home.appendingPathComponent("notes.txt").path
        let copy = home.appendingPathComponent("made/copy.txt").path
        #expect(HostFiles.kind(ofItemAt: notes) == .file)
        #expect(HostFiles.kind(ofItemAt: home.path) == .directory)
        #expect(HostFiles.kind(ofItemAt: copy) == nil)
        try HostFiles.replace(file: copy, with: Array("first".utf8))
        #expect(try HostFiles.contents(ofFile: copy) == Array("first".utf8))
        try HostFiles.copy(file: notes, to: copy)
        #expect(onDisk("Home/made/copy.txt") == Data("notes".utf8), "over what was there")
        #expect(try Foundation.FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("made").path) == ["copy.txt"])
        #expect(try HostFiles.contents(ofFile: home.appendingPathComponent("none").path) == nil)
        #expect(failure { try HostFiles.copy(file: home.path, to: copy) } == .isDirectory)
        #expect(failure { try HostFiles.copy(file: home.appendingPathComponent("none").path, to: copy) } == .notFound)
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
