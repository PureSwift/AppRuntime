import DynamicRuntime

/// The outcome of one `Files` operation. The host calls exactly one of
/// these, once, on the main thread.
@DynamicCallback("org.pureswift.files.FileCallback")
public protocol FileCallback: AnyObject {

    func didComplete()

    func didRead(_ data: [UInt8])

    /// Names, sorted by their UTF-8 bytes. A directory's ends in `/`.
    func didList(_ names: [String])

    /// `kind` is a `FileKind` raw value. `modified` is milliseconds since
    /// 1970 UTC, or 0 where the host doesn't know.
    func didGetAttributes(kind: Int32, size: Int64, modified: Int64)

    /// `error` is a `FileError` raw value.
    func didFail(_ error: Int32)
}
