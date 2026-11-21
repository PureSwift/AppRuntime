import Dispatch
import DynamicFiles
import DynamicRuntime
import RuntimeABI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The `Files` contract over a POSIX file system: what the Darwin and Linux
/// hosts, and any other with one, register.
///
/// A host says where each `FileDirectory` is, once, before the app starts:
///
/// ```swift
/// try HostFiles.configure(HostFiles.Configuration(directories: [
///     .documents: container + "/Documents",
///     .data: container + "/Library/Application Support",
///     .caches: container + "/Library/Caches",
///     .temporary: container + "/tmp",
///     .bundle: bundle + "/resources",
/// ]))
/// HostFilesModule.register(in: runtime)
/// ```
///
/// Each operation runs on a serial queue, so they take effect in the order
/// they were issued, and answers on the main thread.
///
/// A file or folder the user picked is a directory too, for as long as the
/// app holds it: `grant(_:)` makes one and `revoke(_:)` ends it. Another
/// contract that's given a directory and a path asks `path(of:path:)` where
/// the file is, so it reaches the app's own files and the user's alike.
public final class HostFiles: Files {

    /// A file or folder outside the app's own directories, which `Files`
    /// reaches while the grant lasts.
    public struct Grant: Equatable, Sendable {

        /// An absolute path.
        public var path: String

        /// A file is the directory's empty path, with nothing under it. A
        /// folder is a directory like the app's own.
        public var kind: FileKind

        /// Whether writes are let through. Otherwise they're `readOnly`.
        public var isWritable: Bool

        public init(path: String, kind: FileKind, isWritable: Bool) {
            self.path = path
            self.kind = kind
            self.isWritable = isWritable
        }
    }

    public struct Configuration {

        /// Where each directory is: an absolute path. One that's missing
        /// here answers `notFound`.
        public var directories: [FileDirectory: String]

        /// The most bytes one read or write passes. More is `tooLarge`.
        public var maximumTransfer: Int

        /// Runs file work off the main thread. The default is a serial
        /// queue; whatever replaces it must keep the order.
        public var work: @Sendable (@escaping @Sendable () -> Void) -> Void

        /// Runs an answer on the main thread. The default is the main
        /// dispatch queue; a host with a loop of its own posts to that.
        public var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

        public init(
            directories: [FileDirectory: String],
            maximumTransfer: Int = 256 << 20,
            work: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
            deliver: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
        ) {
            let queue = DispatchQueue(label: "org.pureswift.runtime.files")
            self.directories = directories
            self.maximumTransfer = maximumTransfer
            self.work = work ?? { queue.async(execute: $0) }
            self.deliver = deliver ?? { DispatchQueue.main.async(execute: $0) }
        }
    }

    nonisolated(unsafe) private static var current: HostFiles?

    /// The next grant's directory. A value is never used twice in a run.
    nonisolated(unsafe) private static var nextGrant = FileDirectory.firstGrant

    /// Changed on the main thread only. Each operation takes a copy as it's
    /// issued, so one that's running keeps the grants it started with.
    private(set) var system: FileSystem

    let configuration: Configuration

    init(_ configuration: Configuration) {
        self.configuration = configuration
        self.system = FileSystem(directories: configuration.directories, maximumTransfer: configuration.maximumTransfer)
    }

    /// Sets where the app's files are. Makes the directories the app writes
    /// to, and empties `temporary`.
    public static func configure(_ configuration: Configuration) throws(FileError) {
        let files = HostFiles(configuration)
        try files.system.prepare()
        // What the user gave the app outlives a change of its directories.
        files.system.grants = current?.system.grants ?? [:]
        current = files
    }

    /// The configured files. Before `configure`, every operation fails.
    public static func shared() -> HostFiles {
        current ?? HostFiles(Configuration(directories: [:]))
    }

    // MARK: Grants

    /// Lets `Files` reach a file or folder the user picked, and says which
    /// directory it is from now on. Call on the main thread.
    public static func grant(_ grant: Grant) -> FileDirectory {
        let files = current ?? HostFiles(Configuration(directories: [:]))
        current = files
        let directory = FileDirectory(rawValue: nextGrant)
        nextGrant += 1
        files.system.grants[directory.rawValue] = grant
        return directory
    }

    /// Ends a grant: its directory answers `notPermitted` from here on.
    /// Operations already issued finish. Call on the main thread.
    public static func revoke(_ directory: FileDirectory) {
        current?.system.grants[directory.rawValue] = nil
    }

    /// What a directory was granted, while it is.
    public static func grant(for directory: FileDirectory) -> Grant? {
        current?.system.grants[directory.rawValue]
    }

    /// Where a file is: the absolute path of `path` in `directory`, checked
    /// as `Files` checks it. For another contract that takes a directory and
    /// a path, such as a media player. Call on the main thread.
    public static func path(of directory: Int32, path: String, writing: Bool = false) throws(FileError) -> String {
        try shared().system.resolve(directory, path, writing: writing)
    }

    /// The files as they are now, for another contract that reads or
    /// writes a whole file as `Files` would, off the main thread: a text
    /// loaded into an editor, say. Take it on the main thread, where the
    /// grants are; use it on any one thread.
    public static func snapshot() -> Snapshot {
        if let wholeFiles {
            return Snapshot(access: wholeFiles)
        }
        return Snapshot(access: shared().system)
    }

    /// The files a snapshot reads and writes, for a host whose files aren't
    /// all `HostFiles`': an Android app's bundle is its APK's assets, and a
    /// document the user picked a content URI. `nil`, the default, is
    /// `HostFiles`' own.
    nonisolated(unsafe) public static var wholeFiles: (any WholeFileAccess)?

    /// `Files`' reads and writes, with the grants there were when it was
    /// taken.
    public struct Snapshot: Sendable {

        let access: any WholeFileAccess

        /// The file's size in bytes.
        public func size(_ directory: Int32, path: String) throws(FileError) -> Int64 {
            try access.size(directory, path: path)
        }

        /// The whole file.
        public func contents(_ directory: Int32, path: String) throws(FileError) -> [UInt8] {
            try access.contents(directory, path: path)
        }

        /// Replaces the file, atomically where `Files` can.
        public func write(_ data: [UInt8], to directory: Int32, path: String) throws(FileError) {
            try access.write(data, to: directory, path: path)
        }
    }

    // MARK: A host's own files

    // Absolute paths, for what a host keeps beside the app's files and for
    // the contracts built on grants. Synchronous: not for the main thread
    // with a large file.

    /// The whole file; `nil` when there's none.
    public static func contents(ofFile path: String) throws(FileError) -> [UInt8]? {
        try FileSystem.contents(ofFile: path)
    }

    /// Replaces the file, atomically, making the directories above it.
    public static func replace(file path: String, with data: [UInt8]) throws(FileError) {
        try FileSystem(directories: [:], maximumTransfer: 0).makeDirectories(FileSystem.parent(path))
        try FileSystem.replace(file: path, with: data)
    }

    /// Makes the directories a file at an absolute path goes in, as a
    /// write through `Files` does: for another contract's host that hands
    /// the path to something that writes the file itself, such as a
    /// camera. A file where one of them would be is `notDirectory`.
    public static func makeDirectories(aboveFile path: String) throws(FileError) {
        do throws(FileError) {
            try FileSystem(directories: [:], maximumTransfer: 0).makeDirectories(FileSystem.parent(path))
        } catch .alreadyExists {
            throw .notDirectory
        }
    }

    /// Copies a file over whatever is at `destination`, atomically: for a
    /// save the user confirmed in a picker.
    public static func copy(file source: String, to destination: String) throws(FileError) {
        try FileSystem.copy(file: source, replacing: destination)
    }

    /// What's at a path; `nil` when nothing is.
    public static func kind(ofItemAt path: String) -> FileKind? {
        FileSystem.kind(ofItemAt: path)
    }

    /// Runs `operation` off the main thread, and answers `callback` on it.
    private func run(_ callback: any FileCallback, _ operation: @escaping (FileSystem) -> Result<FileSystem.Answer, FileError>) {
        let system = self.system
        let deliver = configuration.deliver
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld(callback)
        let operation = Unchecked(operation)
        configuration.work {
            let answer = Unchecked(operation.value(system))
            deliver {
                guard let callback = held.take() else { return }
                switch answer.value {
                case .success(.complete):
                    callback.didComplete()
                case .success(.data(let data)):
                    callback.didRead(data)
                case .success(.names(let names)):
                    callback.didList(names)
                case .success(.attributes(let attributes)):
                    callback.didGetAttributes(kind: attributes.kind.rawValue, size: attributes.size, modified: attributes.modified ?? 0)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    public func read(_ directory: Int32, path: String, offset: Int64, length: Int64, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in .data(try system.read(directory, path, offset: offset, length: length)) }
        }
    }

    public func write(_ directory: Int32, path: String, data: [UInt8], mode: Int32, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in
                try system.write(directory, path, data: data, mode: mode)
                return .complete
            }
        }
    }

    public func list(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in .names(try system.list(directory, path)) }
        }
    }

    public func attributes(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in .attributes(try system.attributes(directory, path)) }
        }
    }

    public func makeDirectory(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in
                try system.makeDirectory(directory, path)
                return .complete
            }
        }
    }

    public func remove(_ directory: Int32, path: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in
                try system.remove(directory, path)
                return .complete
            }
        }
    }

    public func move(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in
                try system.move(directory, path, to: toDirectory, toPath)
                return .complete
            }
        }
    }

    public func copy(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: any FileCallback) {
        run(callback) { system in
            FileSystem.attempt { () throws(FileError) in
                try system.copy(directory, path, to: toDirectory, toPath)
                return .complete
            }
        }
    }
}

/// The files module: `Files` and its callback.
public enum HostFilesModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [FilesProxy.descriptor, FileCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        FilesProxy.register(HostFiles.self, in: registrar)
        FileCallbackProxy.registerInterface(in: registrar)
    }
}

/// Carries a value the compiler can't see is used on one thread at a time.
private struct Unchecked<Value>: @unchecked Sendable {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - The file system

/// The contract's operations, done synchronously with POSIX calls. Safe to
/// use from any one thread at a time.
struct FileSystem: Sendable {

    enum Answer {
        case complete
        case data([UInt8])
        case names([String])
        case attributes(FileAttributes)
    }

    /// An operation's answer or its failure.
    static func attempt(_ operation: () throws(FileError) -> Answer) -> Result<Answer, FileError> {
        do throws(FileError) {
            return .success(try operation())
        } catch {
            return .failure(error)
        }
    }

    /// Each directory's path with symbolic links resolved, when it exists.
    let roots: [FileDirectory: String]

    /// What the user gave the app, by directory value.
    var grants: [Int32: HostFiles.Grant] = [:]

    let maximumTransfer: Int

    init(directories: [FileDirectory: String], maximumTransfer: Int) {
        self.roots = directories
        self.maximumTransfer = maximumTransfer
    }

    /// Makes the directories the app writes to, and empties `temporary`.
    func prepare() throws(FileError) {
        for directory in FileDirectory.allCases where directory != .bundle {
            guard let root = roots[directory] else { continue }
            try makeDirectories(root)
        }
        if roots[.temporary] != nil {
            try remove(FileDirectory.temporary.rawValue, "")
        }
    }

    // MARK: Paths

    /// The absolute path of `path` in `directory`, checked: its components
    /// are plain names, and nothing on the way is a link out of the
    /// directory.
    func resolve(_ directory: Int32, _ path: String, writing: Bool = false) throws(FileError) -> String {
        let grant = grants[directory]
        if directory >= FileDirectory.firstGrant {
            guard let grant else {
                throw .notPermitted
            }
            if writing, !grant.isWritable {
                throw .readOnly
            }
        } else {
            guard FileDirectory.allCases.contains(FileDirectory(rawValue: directory)) else {
                throw .invalidPath
            }
            if writing, directory == FileDirectory.bundle.rawValue {
                throw .readOnly
            }
        }
        var components: [Substring] = []
        if !path.isEmpty {
            components = path.split(separator: "/", omittingEmptySubsequences: false)
            for component in components {
                if component.isEmpty || component == "." || component == ".." || component.utf8.contains(0) {
                    throw .invalidPath
                }
            }
        }
        let root: String
        if let grant {
            if grant.kind == .file {
                // The file is the directory's empty path.
                guard components.isEmpty else {
                    throw .notDirectory
                }
                return grant.path
            }
            root = grant.path
        } else if let found = roots[FileDirectory(rawValue: directory)] {
            root = found
        } else {
            throw .notFound
        }
        let full = components.isEmpty ? root : root + "/" + components.joined(separator: "/")
        try confine(full, to: root)
        return full
    }

    /// Fails if the deepest part of `path` that exists resolves to
    /// somewhere outside `root`: a symbolic link out of the directory.
    private func confine(_ path: String, to root: String) throws(FileError) {
        guard let realRoot = Self.realPath(root) else {
            // The directory itself isn't there yet; nothing to follow.
            return
        }
        var candidate = path
        while candidate.utf8.count > root.utf8.count {
            if let real = Self.realPath(candidate) {
                guard real == realRoot || real.hasPrefix(realRoot + "/") else {
                    throw .invalidPath
                }
                return
            }
            guard errno == ENOENT || errno == ENOTDIR, let slash = candidate.lastIndex(of: "/") else {
                throw Self.error(errno)
            }
            candidate = String(candidate[..<slash])
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[..<slash])
    }

    static func error(_ code: Int32) -> FileError {
        switch code {
        case ENOENT: return .notFound
        case EEXIST, ENOTEMPTY: return .alreadyExists
        case ENOTDIR: return .notDirectory
        case EISDIR: return .isDirectory
        case ENOSPC, EDQUOT, EFBIG: return .outOfSpace
        case EROFS: return .readOnly
        case EACCES, EPERM: return .notPermitted
        case ENAMETOOLONG, ELOOP, EINVAL: return .invalidPath
        default: return .unknown
        }
    }

    /// What's at `path`, following a link; `nil` when nothing is.
    private func status(_ path: String) throws(FileError) -> stat? {
        var value = stat()
        if stat(path, &value) == 0 {
            return value
        }
        if errno == ENOENT || errno == ENOTDIR {
            return nil
        }
        throw Self.error(errno)
    }

    private static func isDirectory(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func modified(_ value: stat) -> Int64 {
        #if canImport(Darwin)
        let time = value.st_mtimespec
        #else
        let time = value.st_mtim
        #endif
        return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
    }

    /// `mkdir -p`. A file in the way is `notDirectory`, or `alreadyExists`
    /// when it's where the last directory would go.
    func makeDirectories(_ path: String) throws(FileError) {
        if let existing = try status(path) {
            guard Self.isDirectory(existing) else { throw .alreadyExists }
            return
        }
        let above = Self.parent(path)
        if above != path, !above.isEmpty {
            do throws(FileError) {
                try makeDirectories(above)
            } catch .alreadyExists {
                throw .notDirectory
            }
        }
        if mkdir(path, 0o755) != 0, errno != EEXIST {
            throw Self.error(errno)
        }
    }

    /// Makes the directories a new file or directory at `path` goes in. A
    /// file where one of them would be is `notDirectory`.
    private func makeDirectoriesAbove(_ path: String) throws(FileError) {
        do throws(FileError) {
            try makeDirectories(Self.parent(path))
        } catch .alreadyExists {
            throw .notDirectory
        }
    }

    // MARK: Operations

    func read(_ directory: Int32, _ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8] {
        let full = try resolve(directory, path)
        guard offset >= 0, length >= -1 else {
            throw .unknown
        }
        let descriptor = open(full, O_RDONLY)
        guard descriptor >= 0 else {
            throw Self.error(errno)
        }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw Self.error(errno)
        }
        guard !Self.isDirectory(value) else {
            throw .isDirectory
        }
        let available = max(Int64(value.st_size) - offset, 0)
        let wanted = length < 0 ? available : min(length, available)
        guard wanted <= Int64(maximumTransfer) else {
            throw .tooLarge
        }
        var bytes = [UInt8](repeating: 0, count: Int(wanted))
        var done = 0
        while done < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.error(errno)
            }
            if count == 0 {
                // The file shrank since it was measured.
                bytes.removeSubrange(done...)
                break
            }
            done += count
        }
        return bytes
    }

    func write(_ directory: Int32, _ path: String, data: [UInt8], mode: Int32) throws(FileError) {
        let full = try resolve(directory, path, writing: true)
        // A picked file is its directory's empty path.
        let isDocument = grants[directory]?.kind == .file
        guard !path.isEmpty || isDocument else {
            throw .isDirectory
        }
        guard let mode = FileWriteMode(rawValue: mode) else {
            throw .unknown
        }
        guard data.count <= maximumTransfer else {
            throw .tooLarge
        }
        if let existing = try status(full), Self.isDirectory(existing) {
            throw .isDirectory
        }
        if !isDocument {
            try makeDirectoriesAbove(full)
        }
        switch mode {
        case .append:
            let descriptor = open(full, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard descriptor >= 0 else {
                throw Self.error(errno)
            }
            defer { close(descriptor) }
            try Self.writeAll(descriptor, data)
        case .replace:
            try Self.replace(file: full, with: data, inPlaceIfNeeded: isDocument)
        }
    }

    /// Replaces the file at `path` with `data`, atomically: a temporary file
    /// beside it, then a rename over it, so a reader sees the old file or
    /// the new one. The directory must exist.
    ///
    /// The user may have given a file and not the folder it's in, where
    /// nothing can be made beside it. With `inPlaceIfNeeded`, such a file
    /// is written over where it is, which isn't atomic.
    static func replace(file path: String, with data: [UInt8], inPlaceIfNeeded: Bool = false) throws(FileError) {
        let suffix = UInt32.random(in: .min ... .max)
        let temporary = parent(path) + "/." + name(path) + ".tmp-" + String(suffix, radix: 16)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            guard inPlaceIfNeeded, code == EACCES || code == EPERM || code == EROFS else {
                throw error(code)
            }
            let inPlace = open(path, O_WRONLY | O_TRUNC)
            guard inPlace >= 0 else {
                throw error(errno)
            }
            defer { close(inPlace) }
            try writeAll(inPlace, data)
            return
        }
        do throws(FileError) {
            try writeAll(descriptor, data)
        } catch {
            close(descriptor)
            unlink(temporary)
            throw error
        }
        close(descriptor)
        if rename(temporary, path) != 0 {
            let code = errno
            unlink(temporary)
            throw Self.error(code)
        }
    }

    /// Copies the file at `source` over whatever is at `destination`: a
    /// temporary file beside it, then a rename, a block at a time.
    static func copy(file source: String, replacing destination: String) throws(FileError) {
        let input = open(source, O_RDONLY)
        guard input >= 0 else {
            throw error(errno)
        }
        defer { close(input) }
        var value = stat()
        guard fstat(input, &value) == 0 else {
            throw error(errno)
        }
        guard !isDirectory(value) else {
            throw .isDirectory
        }
        let suffix = UInt32.random(in: .min ... .max)
        let temporary = parent(destination) + "/." + name(destination) + ".tmp-" + String(suffix, radix: 16)
        let output = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else {
            throw error(errno)
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var position: off_t = 0
        do throws(FileError) {
            while true {
                let count = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress!, $0.count, position) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw error(errno)
                }
                if count == 0 { break }
                try writeAll(output, Array(buffer[..<count]))
                position += off_t(count)
            }
        } catch {
            close(output)
            unlink(temporary)
            throw error
        }
        close(output)
        if rename(temporary, destination) != 0 {
            let code = errno
            unlink(temporary)
            throw Self.error(code)
        }
    }

    /// What's at `path`, following a link; `nil` when nothing is.
    static func kind(ofItemAt path: String) -> FileKind? {
        var value = stat()
        guard stat(path, &value) == 0 else {
            return nil
        }
        return isDirectory(value) ? .directory : .file
    }

    /// The whole file at `path`; `nil` when there's none.
    static func contents(ofFile path: String) throws(FileError) -> [UInt8]? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw error(errno)
        }
        defer { close(descriptor) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, $0.count, off_t(bytes.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw error(errno)
            }
            if count == 0 { break }
            bytes += buffer[..<count]
        }
        return bytes
    }

    private static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func writeAll(_ descriptor: Int32, _ data: [UInt8]) throws(FileError) {
        var done = 0
        while done < data.count {
            let count = data.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                Darwin.write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                #elseif canImport(Glibc)
                Glibc.write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                #elseif canImport(Musl)
                Musl.write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                #else
                Android.write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw error(errno)
            }
            done += count
        }
    }

    /// The entries of the directory at `path`, without `.` and `..`.
    private func entries(_ path: String) throws(FileError) -> [String] {
        guard let stream = opendir(path) else {
            throw Self.error(errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    func list(_ directory: Int32, _ path: String) throws(FileError) -> [String] {
        let full = try resolve(directory, path)
        // By their bytes, so every host sorts the same way.
        let names = try entries(full).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var listed: [String] = []
        for name in names {
            guard let value = try status(full + "/" + name) else {
                // Removed since it was listed, or a link to nothing.
                continue
            }
            listed.append(Self.isDirectory(value) ? name + "/" : name)
        }
        return listed
    }

    func attributes(_ directory: Int32, _ path: String) throws(FileError) -> FileAttributes {
        let full = try resolve(directory, path)
        guard let value = try status(full) else {
            throw .notFound
        }
        let isDirectory = Self.isDirectory(value)
        return FileAttributes(
            kind: isDirectory ? .directory : .file,
            size: isDirectory ? 0 : Int64(value.st_size),
            modified: Self.modified(value)
        )
    }

    func makeDirectory(_ directory: Int32, _ path: String) throws(FileError) {
        try makeDirectories(try resolve(directory, path, writing: true))
    }

    func remove(_ directory: Int32, _ path: String) throws(FileError) {
        let full = try resolve(directory, path, writing: true)
        if path.isEmpty {
            guard grants[directory] == nil else {
                // What the user picked stays where it is, and as it is.
                throw .invalidPath
            }
            // The directory itself stays; what's in it goes.
            guard try status(full) != nil else { return }
            for name in try entries(full) {
                try removeTree(full + "/" + name)
            }
        } else {
            try removeTree(full)
        }
    }

    /// Removes a file, a link, or a directory and all in it. Fine if it's
    /// gone.
    private func removeTree(_ path: String) throws(FileError) {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw Self.error(errno)
        }
        if Self.isDirectory(value) {
            for name in try entries(path) {
                try removeTree(path + "/" + name)
            }
            if rmdir(path) != 0, errno != ENOENT {
                throw Self.error(errno)
            }
        } else if unlink(path) != 0, errno != ENOENT {
            throw Self.error(errno)
        }
    }

    /// The checks a move and a copy share; returns both absolute paths.
    private func transfer(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String, removesSource: Bool) throws(FileError) -> (source: String, destination: String) {
        let source = try resolve(directory, path, writing: removesSource)
        let destination = try resolve(toDirectory, toPath, writing: true)
        // A directory itself can't be moved, copied or replaced. What the
        // user picked can be copied from, whole.
        let copiesDocument = path.isEmpty && !removesSource && grants[directory] != nil
        guard !path.isEmpty || copiesDocument, !toPath.isEmpty else {
            throw .invalidPath
        }
        guard try status(source) != nil else {
            throw .notFound
        }
        guard try status(destination) == nil else {
            throw .alreadyExists
        }
        guard destination != source, !destination.hasPrefix(source + "/") else {
            // Into itself.
            throw .invalidPath
        }
        try makeDirectoriesAbove(destination)
        return (source, destination)
    }

    func move(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) throws(FileError) {
        let (source, destination) = try transfer(directory, path, to: toDirectory, toPath, removesSource: true)
        if rename(source, destination) == 0 {
            return
        }
        guard errno == EXDEV else {
            throw Self.error(errno)
        }
        // Another volume, as `temporary` often is: copy, then remove.
        try copyTree(source, destination)
        try removeTree(source)
    }

    func copy(_ directory: Int32, _ path: String, to toDirectory: Int32, _ toPath: String) throws(FileError) {
        let (source, destination) = try transfer(directory, path, to: toDirectory, toPath, removesSource: false)
        do throws(FileError) {
            try copyTree(source, destination)
        } catch {
            // Leave nothing half-copied.
            try? removeTree(destination)
            throw error
        }
    }

    private func copyTree(_ source: String, _ destination: String) throws(FileError) {
        var value = stat()
        guard lstat(source, &value) == 0 else {
            throw Self.error(errno)
        }
        switch value.st_mode & S_IFMT {
        case S_IFDIR:
            if mkdir(destination, 0o755) != 0 {
                throw Self.error(errno)
            }
            for name in try entries(source) {
                try copyTree(source + "/" + name, destination + "/" + name)
            }
        case S_IFREG:
            let input = open(source, O_RDONLY)
            guard input >= 0 else {
                throw Self.error(errno)
            }
            defer { close(input) }
            let output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard output >= 0 else {
                throw Self.error(errno)
            }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var position: off_t = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress!, $0.count, position) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.error(errno)
                }
                if count == 0 { break }
                try Self.writeAll(output, Array(buffer[..<count]))
                position += off_t(count)
            }
        default:
            // Links and special files aren't copied.
            break
        }
    }
}

/// Whole files as `Files` names them, read and written off the main
/// thread from any one thread at a time: what `HostFiles.snapshot()` uses.
/// A host whose files aren't all `HostFiles`' sets `HostFiles.wholeFiles`
/// to its own, with `Files`' rules and errors.
public protocol WholeFileAccess: Sendable {

    /// The file's size in bytes; `isDirectory` for a directory.
    func size(_ directory: Int32, path: String) throws(FileError) -> Int64

    /// The whole file.
    func contents(_ directory: Int32, path: String) throws(FileError) -> [UInt8]

    /// Replaces the file, atomically where the host can, making the
    /// directories above it.
    func write(_ data: [UInt8], to directory: Int32, path: String) throws(FileError)
}

extension FileSystem: WholeFileAccess {

    func size(_ directory: Int32, path: String) throws(FileError) -> Int64 {
        let attributes = try attributes(directory, path)
        guard attributes.kind == .file else {
            throw .isDirectory
        }
        return attributes.size
    }

    func contents(_ directory: Int32, path: String) throws(FileError) -> [UInt8] {
        try read(directory, path, offset: 0, length: -1)
    }

    func write(_ data: [UInt8], to directory: Int32, path: String) throws(FileError) {
        try write(directory, path, data: data, mode: FileWriteMode.replace.rawValue)
    }
}
