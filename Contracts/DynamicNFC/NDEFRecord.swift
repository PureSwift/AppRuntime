import DynamicRuntime

/// One NDEF record.
@DynamicRuntime("org.pureswift.nfc.NDEFRecord")
public protocol NDEFRecord: AnyObject {

    /// `format` is an `NDEFTypeNameFormat` raw value.
    static func make(format: Int32, type: [UInt8], identifier: [UInt8], payload: [UInt8]) -> Self

    /// A well-known URI record, using the URI prefix codes. Nil if `uri`
    /// isn't valid.
    static func makeURI(_ uri: String) -> Self?

    /// A well-known text record (UTF-8). `locale` is a BCP 47 language
    /// code such as `en`.
    static func makeText(_ text: String, locale: String) -> Self

    /// An `NDEFTypeNameFormat` raw value.
    func typeNameFormat() -> Int32

    func type() -> [UInt8]

    func identifier() -> [UInt8]

    func payload() -> [UInt8]

    /// The URI of a well-known URI record (prefix expanded), else nil.
    func uri() -> String?

    /// The text of a well-known text record, else nil.
    func text() -> String?
}
