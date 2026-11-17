import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The app's files: Foundation's `FileManager`, for a guest.
///
/// ```swift
/// let files = FileManager.default
/// let level = try await files.contents(at: .bundle / "levels/1.map")
/// try await files.write(save, to: .documents / "saves/slot1.sav")
/// for name in try await files.contentsOfDirectory(at: .documents / "saves") { … }
/// ```
///
/// The names follow Foundation's. What differs: a file is a `FilePath` (a
/// named directory and a relative path) where Foundation takes a URL, and
/// every call is asynchronous, because a browser's file storage is. Each
/// has a completion-handler form too, for code that isn't `async` and for
/// slices built without the concurrency runtime.
///
/// It's guest-side only, over the `Files` contract. The guest is
/// single-threaded (§6.4).
public final class FileManager: @unchecked Sendable {

    public static let `default` = FileManager()

    /// The host's files, made when first used.
    private var made: (any Files)?

    public init() { }

    private var files: any Files {
        if let made {
            return made
        }
        let files = FilesProxy.shared()
        made = files
        return files
    }

    // MARK: Completion handlers

    /// The whole file.
    public func contents(at path: FilePath, completion: @escaping (Result<[UInt8], FileError>) -> Void) {
        contents(at: path, offset: 0, length: nil, completion: completion)
    }

    /// `length` bytes from `offset`, or to the end when `length` is `nil`.
    /// Past the end there's less, or nothing.
    public func contents(at path: FilePath, offset: Int64, length: Int64?, completion: @escaping (Result<[UInt8], FileError>) -> Void) {
        files.read(path.directory.rawValue, path: path.path, offset: offset, length: length ?? -1, callback: Receiver { outcome in
            if case .data(let data) = outcome {
                completion(.success(data))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Replaces the file, atomically, and makes the directories above it.
    public func write(_ data: [UInt8], to path: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.write(path.directory.rawValue, path: path.path, data: data, mode: FileWriteMode.replace.rawValue, callback: Receiver.completing(completion))
    }

    /// Adds to the end of the file, creating it.
    public func append(_ data: [UInt8], to path: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.write(path.directory.rawValue, path: path.path, data: data, mode: FileWriteMode.append.rawValue, callback: Receiver.completing(completion))
    }

    /// The names in a directory, sorted. A directory's name ends in `/`.
    public func contentsOfDirectory(at path: FilePath, completion: @escaping (Result<[String], FileError>) -> Void) {
        files.list(path.directory.rawValue, path: path.path, callback: Receiver { outcome in
            if case .names(let names) = outcome {
                completion(.success(names))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    public func attributesOfItem(at path: FilePath, completion: @escaping (Result<FileAttributes, FileError>) -> Void) {
        files.attributes(path.directory.rawValue, path: path.path, callback: Receiver { outcome in
            if case .attributes(let attributes) = outcome {
                completion(.success(attributes))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// Whether there's a file or directory there. `false` only when the
    /// host says it isn't found; other failures are failures.
    public func fileExists(at path: FilePath, completion: @escaping (Result<Bool, FileError>) -> Void) {
        attributesOfItem(at: path) { result in
            switch result {
            case .success:
                completion(.success(true))
            case .failure(.notFound):
                completion(.success(false))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Makes the directory and those above it. Fine if it's there already.
    public func createDirectory(at path: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.makeDirectory(path.directory.rawValue, path: path.path, callback: Receiver.completing(completion))
    }

    /// Removes a file, or a directory and everything in it. Fine if it's
    /// gone already.
    public func removeItem(at path: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.remove(path.directory.rawValue, path: path.path, callback: Receiver.completing(completion))
    }

    /// Fails with `alreadyExists` if there's something at `destination`.
    public func moveItem(at path: FilePath, to destination: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.move(path.directory.rawValue, path: path.path, toDirectory: destination.directory.rawValue, toPath: destination.path, callback: Receiver.completing(completion))
    }

    /// Fails with `alreadyExists` if there's something at `destination`.
    public func copyItem(at path: FilePath, to destination: FilePath, completion: @escaping (Result<Void, FileError>) -> Void) {
        files.copy(path.directory.rawValue, path: path.path, toDirectory: destination.directory.rawValue, toPath: destination.path, callback: Receiver.completing(completion))
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4): in host-side Swift, that's the caller's actor, and not a
    // thread of the pool.

    #if !EMBEDDED_NO_CONCURRENCY
    /// The whole file.
    public nonisolated(nonsending) func contents(at path: FilePath) async throws(FileError) -> [UInt8] {
        try await wait { self.contents(at: path, completion: $0) }
    }

    /// `length` bytes from `offset`, or to the end when `length` is `nil`.
    public nonisolated(nonsending) func contents(at path: FilePath, offset: Int64, length: Int64?) async throws(FileError) -> [UInt8] {
        try await wait { self.contents(at: path, offset: offset, length: length, completion: $0) }
    }

    /// Replaces the file, atomically, and makes the directories above it.
    public nonisolated(nonsending) func write(_ data: [UInt8], to path: FilePath) async throws(FileError) {
        try await wait { self.write(data, to: path, completion: $0) }
    }

    /// Adds to the end of the file, creating it.
    public nonisolated(nonsending) func append(_ data: [UInt8], to path: FilePath) async throws(FileError) {
        try await wait { self.append(data, to: path, completion: $0) }
    }

    /// The names in a directory, sorted. A directory's name ends in `/`.
    public nonisolated(nonsending) func contentsOfDirectory(at path: FilePath) async throws(FileError) -> [String] {
        try await wait { self.contentsOfDirectory(at: path, completion: $0) }
    }

    public nonisolated(nonsending) func attributesOfItem(at path: FilePath) async throws(FileError) -> FileAttributes {
        try await wait { self.attributesOfItem(at: path, completion: $0) }
    }

    public nonisolated(nonsending) func fileExists(at path: FilePath) async throws(FileError) -> Bool {
        try await wait { self.fileExists(at: path, completion: $0) }
    }

    public nonisolated(nonsending) func createDirectory(at path: FilePath) async throws(FileError) {
        try await wait { self.createDirectory(at: path, completion: $0) }
    }

    public nonisolated(nonsending) func removeItem(at path: FilePath) async throws(FileError) {
        try await wait { self.removeItem(at: path, completion: $0) }
    }

    public nonisolated(nonsending) func moveItem(at path: FilePath, to destination: FilePath) async throws(FileError) {
        try await wait { self.moveItem(at: path, to: destination, completion: $0) }
    }

    public nonisolated(nonsending) func copyItem(at path: FilePath, to destination: FilePath) async throws(FileError) {
        try await wait { self.copyItem(at: path, to: destination, completion: $0) }
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, FileError>) -> Void) -> Void) async throws(FileError) -> Value {
        try await withCallback { (callback: Callback<Value, FileError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// What a `FileCallback` was told.
private enum Outcome {

    case complete
    case data([UInt8])
    case names([String])
    case attributes(FileAttributes)
    case failure(FileError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: FileError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: FileCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didComplete`.
    static func completing(_ completion: @escaping (Result<Void, FileError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didRead(_ data: [UInt8]) {
        answer(.data(data))
    }

    func didList(_ names: [String]) {
        answer(.names(names))
    }

    func didGetAttributes(kind: Int32, size: Int64, modified: Int64) {
        // A kind from a newer host is some other thing that isn't a directory.
        answer(.attributes(FileAttributes(kind: FileKind(rawValue: kind) ?? .file, size: size, modified: modified == 0 ? nil : modified)))
    }

    func didFail(_ error: Int32) {
        answer(.failure(FileError(rawValue: error) ?? .unknown))
    }
}
