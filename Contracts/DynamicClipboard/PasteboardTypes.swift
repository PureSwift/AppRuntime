/// Guest-side names for what the `Clipboard` contract carries.

/// What the clipboard may hold.
public struct ClipboardKinds: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let text = ClipboardKinds(rawValue: 1 << 0)

    public static let url = ClipboardKinds(rawValue: 1 << 1)

    public static let image = ClipboardKinds(rawValue: 1 << 2)

    public static let all: ClipboardKinds = [.text, .url, .image]
}

/// How something is copied.
public struct PasteboardOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// A password or a code: the platform keeps it out of previews,
    /// clipboard history and other devices, where it can.
    public static let sensitive = PasteboardOptions(rawValue: 1 << 0)
}

/// The image files a clipboard carries.
public enum PasteboardImageType: String, Sendable {

    case png = "image/png"

    case jpeg = "image/jpeg"

    public var mimeType: String {
        rawValue
    }

    /// For a file's name: `png` or `jpg`.
    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    /// Which of the two an image file is, by its first bytes; `nil` for
    /// anything else.
    public static func detect(_ data: [UInt8]) -> PasteboardImageType? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= png.count, Array(data[..<png.count]) == png {
            return .png
        }
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return .jpeg
        }
        return nil
    }
}

/// An image from the clipboard: an image file's bytes.
public struct PasteboardImage: Equatable, Sendable {

    public var data: [UInt8]

    public var type: PasteboardImageType

    public init(data: [UInt8], type: PasteboardImageType) {
        self.data = data
        self.type = type
    }
}

/// Why a copy or a paste failed. Nothing to paste isn't a failure: a read
/// gives `nil`.
public enum PasteboardError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The operation may
    /// still happen. Hosts never send it.
    case cancelled = 1

    /// The user or the platform refused: the call didn't come from a user
    /// action, the app isn't in front, or the user said no.
    case notAllowed = 2

    /// This host can't hold the kind: an image, on a host with text only.
    case unsupported = 3

    /// Not a PNG or a JPEG, or a file that isn't there.
    case invalidData = 4

    /// More than the host passes in one call: use the file forms.
    case tooLarge = 5
}
