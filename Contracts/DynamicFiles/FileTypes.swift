/// Guest-side names for what the `Files` contract carries.

/// A place the platform keeps an app's files. No absolute path means the
/// same thing on every platform, so a file is one of these and a path
/// inside it.
public enum FileDirectory: Int32, Sendable, CaseIterable {

    /// What the user made. Backed up where the platform backs up.
    case documents = 0

    /// What the app needs and the user never sees. Backed up.
    case data = 1

    /// What can be made again. The system may delete it when space is
    /// short.
    case caches = 2

    /// For this run only: emptied when the app next starts.
    case temporary = 3

    /// The app's resources. Read-only.
    case bundle = 4
}

/// A file or directory: a `FileDirectory` and a relative path inside it,
/// with `/` between components.
///
/// ```swift
/// let save: FilePath = .documents / "saves/slot1.sav"
/// let folder = save.deletingLastComponent      // documents: saves
/// ```
///
/// The empty path is the directory itself. A path the host can't accept
/// (`..`, an empty component, a NUL) fails with `FileError.invalidPath`
/// when it's used; `isValid` says so beforehand.
public struct FilePath: Equatable, Hashable, Sendable {

    public var directory: FileDirectory

    /// Components joined with `/`, with none at either end.
    public var path: String

    /// A trailing `/`, as a listing puts after a directory's name, is
    /// dropped.
    public init(_ directory: FileDirectory, _ path: String = "") {
        self.directory = directory
        self.path = path.utf8.last == UInt8(ascii: "/") ? String(path.dropLast()) : path
    }

    public var components: [String] {
        path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    /// The file's or directory's own name; empty for the directory itself.
    public var lastComponent: String {
        components.last ?? ""
    }

    /// The directory this is in. The directory itself has none above it,
    /// and gives itself.
    public var deletingLastComponent: FilePath {
        var parts = components
        guard !parts.isEmpty else { return self }
        parts.removeLast()
        return FilePath(directory, parts.joined(separator: "/"))
    }

    public func appending(_ component: String) -> FilePath {
        FilePath(directory, path.isEmpty ? component : path + "/" + component)
    }

    /// Whether every host accepts it: no empty, `.` or `..` component, and
    /// no NUL.
    public var isValid: Bool {
        for component in components {
            if component.isEmpty || component == "." || component == ".." || component.utf8.contains(0) {
                return false
            }
        }
        return true
    }

    public static func / (path: FilePath, component: String) -> FilePath {
        path.appending(component)
    }
}

/// `.documents / "notes/todo.txt"`
public func / (directory: FileDirectory, path: String) -> FilePath {
    FilePath(directory, path)
}

/// Whether a `Files` write replaces a file or adds to it.
public enum FileWriteMode: Int32, Sendable {

    /// Replaces the file, atomically: a reader sees the old file or the new
    /// one, never part of each.
    case replace = 0

    /// Adds to the end, creating the file.
    case append = 1
}

public enum FileKind: Int32, Sendable {
    case file = 0
    case directory = 1
}

public struct FileAttributes: Equatable, Sendable {

    public var kind: FileKind

    /// Bytes; 0 for a directory.
    public var size: Int64

    /// Milliseconds since 1970 UTC; `nil` where the host doesn't know, as
    /// for a file inside an Android app's package.
    public var modified: Int64?

    public init(kind: FileKind, size: Int64, modified: Int64?) {
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public var isDirectory: Bool {
        kind == .directory
    }
}

/// Why a file operation failed.
public enum FileError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting for the operation was cancelled. The
    /// operation may still happen. Hosts never send it.
    case cancelled = 1

    case notFound = 2

    /// There's already something where a move or copy would put its result,
    /// or a file where a directory was to be made.
    case alreadyExists = 3

    /// A file where a directory is needed.
    case notDirectory = 4

    /// A directory where a file is needed.
    case isDirectory = 5

    case invalidPath = 6

    /// A change to the bundle.
    case readOnly = 7

    case outOfSpace = 8

    /// More than this host passes in one call: read it in ranges, or write
    /// it with `append`.
    case tooLarge = 9
}
