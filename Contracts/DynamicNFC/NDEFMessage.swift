import DynamicRuntime

/// An NDEF message: an ordered list of records.
@DynamicRuntime("org.pureswift.nfc.NDEFMessage")
public protocol NDEFMessage: AnyObject {

    static func make(_ records: [NDEFRecord]) -> Self

    func records() -> [NDEFRecord]

    /// Encoded length in bytes, to compare with a tag's capacity.
    func length() -> Int32
}
