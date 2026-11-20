import DynamicRuntime

/// The app's own files, and the files in its bundle (§7.9). App code uses
/// `FileManager`, which wraps this contract.
///
/// A file is named by a directory (a `FileDirectory` raw value) and a
/// relative path inside it, with `/` between components. Every operation
/// completes through its `callback`, which the host holds until it has
/// called exactly one of its methods, on the main thread: a browser's file
/// storage can't be used synchronously there, and no host should read a
/// disk there.
///
/// It needs no capability: these are the app's own directories. A directory
/// of 256 or more is a document the user picked (`DynamicDocuments`), which
/// the picker's capability covers; one the app no longer holds answers
/// `notPermitted`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `FileManager`, in the app's container |
/// | Android | `java.io.File` under `filesDir` and `cacheDir`; `AssetManager` for the bundle |
/// | Linux | the `/data` container; `/app/resources` for the bundle |
/// | Browser | the origin's private file system; `fetch` for the bundle |
@DynamicRuntime("org.pureswift.files.Files")
public protocol Files: AnyObject {

    static func shared() -> Self

    /// Reads `length` bytes from `offset`, or to the end when `length` is
    /// -1. Past the end there's less, or nothing. Answers `didRead`.
    func read(_ directory: Int32, path: String, offset: Int64, length: Int64, callback: FileCallback)

    /// Writes `data`. `mode` is a `FileWriteMode` raw value: replacing is
    /// atomic, and both make the directories above the file. Answers
    /// `didComplete`.
    func write(_ directory: Int32, path: String, data: [UInt8], mode: Int32, callback: FileCallback)

    /// The names in a directory. Answers `didList`.
    func list(_ directory: Int32, path: String, callback: FileCallback)

    /// Answers `didGetAttributes`, or `didFail` with `notFound`.
    func attributes(_ directory: Int32, path: String, callback: FileCallback)

    /// Makes a directory and those above it. Fine if it's there already.
    /// Answers `didComplete`.
    func makeDirectory(_ directory: Int32, path: String, callback: FileCallback)

    /// Removes a file, or a directory and everything in it. Fine if it's
    /// gone already. The empty path empties the directory. Answers
    /// `didComplete`.
    func remove(_ directory: Int32, path: String, callback: FileCallback)

    /// Fails with `alreadyExists` if there's something at the destination.
    /// Answers `didComplete`.
    func move(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: FileCallback)

    /// A file, or a directory and everything in it. Fails with
    /// `alreadyExists` if there's something at the destination. Answers
    /// `didComplete`.
    func copy(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: FileCallback)
}
