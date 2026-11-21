import DynamicText

/// A file's bytes to a text and back, by the rules every host follows
/// (`Documentation/Contracts/TextEditor.md`): the five encodings each
/// host has, the byte-order mark, no guessing, no replacing of invalid
/// bytes, and `\n` as the only line break in a text.
///
/// It has no state and touches nothing shared, so it's used off the main
/// thread.
public enum TextCoding {

    /// A file, read.
    public struct Decoded: Equatable, Sendable {

        /// With `\n` as its only line break.
        public var text: String

        /// The encoding it was read in, by its IANA name.
        public var encoding: String

        /// The file's first kind of line break; `lf` when it has none.
        public var lineEnding: LineEnding

        public var hasByteOrderMark: Bool
    }

    /// An encoding beyond the five, from a platform that has it. Each
    /// answers `nil` for bytes or text the encoding can't hold.
    public struct Extra: Sendable {

        public var decode: @Sendable (_ bytes: [UInt8], _ encoding: String) -> String?

        public var encode: @Sendable (_ text: String, _ encoding: String) -> [UInt8]?

        public init(
            decode: @escaping @Sendable (_ bytes: [UInt8], _ encoding: String) -> String?,
            encode: @escaping @Sendable (_ text: String, _ encoding: String) -> [UInt8]?
        ) {
            self.decode = decode
            self.encode = encode
        }
    }

    /// The names every host reads and writes.
    public static let required: Set<String> = Set(TextEncoding.required.map(\.rawValue))

    /// A name as it's compared: in lower case.
    public static func normalized(_ name: String) -> String {
        TextEncoding(rawValue: name).rawValue
    }

    // MARK: Reading

    /// Reads a file's bytes. An empty `encoding` takes the byte-order
    /// mark's, or UTF-8. `extra` is asked for an encoding that isn't one
    /// of the five; without it that's `unsupportedEncoding`.
    public static func decode(_ bytes: [UInt8], encoding: String, extra: Extra? = nil) throws(TextError) -> Decoded {
        var name = normalized(encoding)
        var body = bytes[...]
        var hasMark = false
        if name.isEmpty {
            if let mark = marks.first(where: { body.starts(with: $0.bytes) }) {
                name = mark.name
                body = body.dropFirst(mark.bytes.count)
                hasMark = true
            } else {
                name = TextEncoding.utf8.rawValue
            }
        } else if let mark = marks.first(where: { $0.name == name }), body.starts(with: mark.bytes) {
            body = body.dropFirst(mark.bytes.count)
            hasMark = true
        }
        let raw: String
        switch name {
        case TextEncoding.utf8.rawValue:
            raw = try utf8(body)
        case TextEncoding.utf16LittleEndian.rawValue:
            raw = try utf16(body, bigEndian: false)
        case TextEncoding.utf16BigEndian.rawValue:
            raw = try utf16(body, bigEndian: true)
        case TextEncoding.isoLatin1.rawValue:
            raw = singleByte(body) { Unicode.Scalar($0) }
        case TextEncoding.windows1252.rawValue:
            raw = singleByte(body) { windows1252Scalar($0) }
        default:
            guard let extra else {
                throw .unsupportedEncoding
            }
            guard let text = extra.decode(Array(body), name) else {
                throw .undecodable
            }
            raw = text
        }
        let (text, lineEnding) = normalizingLineBreaks(raw)
        return Decoded(text: text, encoding: name, lineEnding: lineEnding, hasByteOrderMark: hasMark)
    }

    private static let marks: [(name: String, bytes: [UInt8])] = [
        (TextEncoding.utf8.rawValue, [0xEF, 0xBB, 0xBF]),
        (TextEncoding.utf16LittleEndian.rawValue, [0xFF, 0xFE]),
        (TextEncoding.utf16BigEndian.rawValue, [0xFE, 0xFF]),
    ]

    private static func utf8(_ bytes: ArraySlice<UInt8>) throws(TextError) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        let hadError = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF8.self, stoppingOnError: true) {
            output.append($0)
        }
        guard !hadError else {
            throw .undecodable
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) throws(TextError) -> String {
        guard bytes.count % 2 == 0 else {
            throw .undecodable
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        var output: [UInt8] = []
        output.reserveCapacity(units.count)
        let hadError = transcode(units.makeIterator(), from: UTF16.self, to: UTF8.self, stoppingOnError: true) {
            output.append($0)
        }
        guard !hadError else {
            throw .undecodable
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func singleByte(_ bytes: ArraySlice<UInt8>, _ scalar: (UInt8) -> Unicode.Scalar) -> String {
        var text = String.UnicodeScalarView()
        text.reserveCapacity(bytes.count)
        for byte in bytes {
            text.append(scalar(byte))
        }
        return String(text)
    }

    /// Windows-1252's 0x80…0x9F, as the WHATWG Encoding Standard has it:
    /// the five bytes the code page leaves undefined are the C1 controls
    /// of the same number, so every byte reads and writes back.
    private static let windows1252High: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static func windows1252Scalar(_ byte: UInt8) -> Unicode.Scalar {
        guard byte >= 0x80, byte <= 0x9F else {
            return Unicode.Scalar(byte)
        }
        return Unicode.Scalar(windows1252High[Int(byte) - 0x80])!
    }

    // MARK: Line breaks

    /// `text` with `\r\n` and `\r` turned into `\n`, and the first kind of
    /// line break it had.
    public static func normalizingLineBreaks(_ text: String) -> (text: String, lineEnding: LineEnding) {
        let lineEnding = firstLineBreak(in: text)
        guard text.utf8.contains(0x0D) else {
            return (text, lineEnding)
        }
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        var skipNewline = false
        for byte in text.utf8 {
            if byte == 0x0D {
                output.append(0x0A)
                skipNewline = true
                continue
            }
            if byte == 0x0A, skipNewline {
                skipNewline = false
                continue
            }
            skipNewline = false
            output.append(byte)
        }
        return (String(decoding: output, as: UTF8.self), lineEnding)
    }

    /// The kind of the first line break in `text`.
    private static func firstLineBreak(in text: String) -> LineEnding {
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x0A {
                return .lf
            }
            if byte == 0x0D {
                return iterator.next() == 0x0A ? .crlf : .cr
            }
        }
        return .lf
    }

    /// `text`, which has `\n` only, with each as `lineEnding`.
    static func applying(_ lineEnding: LineEnding, to text: String) -> String {
        let replacement: [UInt8]
        switch lineEnding {
        case .lf: return text
        case .crlf: replacement = [0x0D, 0x0A]
        case .cr: replacement = [0x0D]
        }
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count + text.utf8.count / 32)
        for byte in text.utf8 {
            if byte == 0x0A {
                output.append(contentsOf: replacement)
            } else {
                output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Writing

    /// A text's bytes for a file. `text` has `\n` only; each is written
    /// as `lineEnding`. An empty `encoding` is UTF-8.
    public static func encode(
        _ text: String, encoding: String, lineEnding: LineEnding, byteOrderMark: Bool, extra: Extra? = nil
    ) throws(TextError) -> [UInt8] {
        var name = normalized(encoding)
        if name.isEmpty {
            name = TextEncoding.utf8.rawValue
        }
        let text = applying(lineEnding, to: text)
        var bytes: [UInt8] = []
        if byteOrderMark, let mark = marks.first(where: { $0.name == name }) {
            bytes = mark.bytes
        }
        switch name {
        case TextEncoding.utf8.rawValue:
            bytes.append(contentsOf: text.utf8)
        case TextEncoding.utf16LittleEndian.rawValue:
            bytes.reserveCapacity(bytes.count + text.utf16.count * 2)
            for unit in text.utf16 {
                bytes.append(UInt8(truncatingIfNeeded: unit))
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
            }
        case TextEncoding.utf16BigEndian.rawValue:
            bytes.reserveCapacity(bytes.count + text.utf16.count * 2)
            for unit in text.utf16 {
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
                bytes.append(UInt8(truncatingIfNeeded: unit))
            }
        case TextEncoding.isoLatin1.rawValue:
            for scalar in text.unicodeScalars {
                guard scalar.value <= 0xFF else {
                    throw .unencodable
                }
                bytes.append(UInt8(scalar.value))
            }
        case TextEncoding.windows1252.rawValue:
            for scalar in text.unicodeScalars {
                guard let byte = windows1252Byte(scalar) else {
                    throw .unencodable
                }
                bytes.append(byte)
            }
        default:
            guard let extra else {
                throw .unsupportedEncoding
            }
            guard let encoded = extra.encode(text, name) else {
                throw .unencodable
            }
            bytes.append(contentsOf: encoded)
        }
        return bytes
    }

    private static func windows1252Byte(_ scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if value < 0x80 || (value >= 0xA0 && value <= 0xFF) {
            return UInt8(value)
        }
        guard value <= 0xFFFF, let index = windows1252High.firstIndex(of: UInt16(value)) else {
            return nil
        }
        return UInt8(0x80 + index)
    }
}
