import DynamicFiles

/// Guest-side names for what the `TextStorage` contract carries.

/// How a file's bytes spell its text, by IANA name.
///
/// Every host reads and writes the five constants. Any other is a name,
/// which a host has or hasn't:
///
/// ```swift
/// let shiftJIS = TextEncoding(name: "shift_jis")
/// if shiftJIS.isSupported { … }
/// ```
public struct TextEncoding: RawRepresentable, Equatable, Hashable, Sendable {

    /// The IANA name, in lower case.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = Self.lowercased(rawValue)
    }

    public init(name: String) {
        self.init(rawValue: name)
    }

    public var name: String {
        rawValue
    }

    public static let utf8 = TextEncoding(rawValue: "utf-8")

    public static let utf16LittleEndian = TextEncoding(rawValue: "utf-16le")

    public static let utf16BigEndian = TextEncoding(rawValue: "utf-16be")

    /// ISO 8859-1. It reads any bytes at all.
    public static let isoLatin1 = TextEncoding(rawValue: "iso-8859-1")

    public static let windows1252 = TextEncoding(rawValue: "windows-1252")

    /// The ones every host has.
    public static let required: [TextEncoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .windows1252]

    /// Whether this host reads and writes it.
    public var isSupported: Bool {
        TextStorageProxy.supportsEncoding(rawValue)
    }

    /// Names are ASCII, so this needs no Unicode tables.
    private static func lowercased(_ name: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.utf8.count)
        for byte in name.utf8 {
            bytes.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// How a file ends its lines. A buffer holds `\n` only; this is what its
/// file had, and what a save writes.
public enum LineEnding: Int32, Sendable {

    /// `\n`: Unix, macOS.
    case lf = 0

    /// `\r\n`: Windows.
    case crlf = 1

    /// `\r`: classic Mac OS.
    case cr = 2
}

/// How `TextBuffer.find` and `replaceAll` search.
public struct TextSearchOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Simple case folding: no locale's rules, and accents count.
    public static let caseInsensitive = TextSearchOptions(rawValue: 1 << 0)

    /// Towards the start of the text.
    public static let backwards = TextSearchOptions(rawValue: 1 << 1)

    /// A match has no letter, digit or underscore on either side.
    public static let wholeWords = TextSearchOptions(rawValue: 1 << 2)

    /// Goes on from the other end of the text when it reaches one.
    public static let wraps = TextSearchOptions(rawValue: 1 << 3)
}

/// One change to a buffer's text, whoever made it. Positions are UTF-16
/// units.
public struct TextEdit: Equatable, Sendable {

    /// What was replaced, in the text as it was.
    public var range: Range<Int>

    /// The length of what replaced it.
    public var insertedLength: Int

    public init(range: Range<Int>, insertedLength: Int) {
        self.range = range
        self.insertedLength = insertedLength
    }

    /// Where the new text is, in the text as it is now.
    public var insertedRange: Range<Int> {
        range.lowerBound ..< range.lowerBound + insertedLength
    }
}

/// Why a load or a save failed.
public enum TextError: Error, Equatable, Sendable {

    case unknown

    /// The file couldn't be read or written.
    case file(FileError)

    /// The file's bytes aren't text in the encoding: the one asked for,
    /// or UTF-8 when none was and the file has no byte-order mark.
    case undecodable

    /// The text has a character the encoding lacks. Nothing was written.
    case unencodable

    /// This host doesn't have the encoding.
    case unsupportedEncoding

    /// Longer than `TextBuffer.maximumLength`.
    case tooLarge

    /// Another load replaced this one, the buffer was released, or the
    /// task waiting was cancelled.
    case cancelled

    /// What a host sends.
    public enum Code: Int32, Sendable {
        case unknown = 0
        case file = 1
        case undecodable = 2
        case unencodable = 3
        case unsupportedEncoding = 4
        case tooLarge = 5
        case cancelled = 6
    }

    public var code: Code {
        switch self {
        case .unknown: return .unknown
        case .file: return .file
        case .undecodable: return .undecodable
        case .unencodable: return .unencodable
        case .unsupportedEncoding: return .unsupportedEncoding
        case .tooLarge: return .tooLarge
        case .cancelled: return .cancelled
        }
    }

    /// The `FileError` raw value a host sends beside the code.
    public var fileCode: Int32 {
        if case .file(let error) = self {
            return error.rawValue
        }
        return 0
    }

    /// From what a host sent. A code from a newer host is `unknown`.
    public init(code: Int32, file: Int32) {
        switch Code(rawValue: code) ?? .unknown {
        case .unknown: self = .unknown
        case .file: self = .file(FileError(rawValue: file) ?? .unknown)
        case .undecodable: self = .undecodable
        case .unencodable: self = .unencodable
        case .unsupportedEncoding: self = .unsupportedEncoding
        case .tooLarge: self = .tooLarge
        case .cancelled: self = .cancelled
        }
    }
}
