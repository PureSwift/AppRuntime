/// A kind of file, by MIME type, file extensions, or both: `UTType`'s place.
///
/// ```swift
/// picker.open([.image])                       // any image
/// picker.open([.png, .jpeg])
/// picker.open([ContentType(mimeType: "application/gpx+xml", fileExtensions: ["gpx"])])
/// ```
///
/// The constants carry `UTType`'s names. A host filters by the MIME type
/// where a type has one, and by its extensions where it doesn't.
public struct ContentType: Equatable, Hashable, Sendable {

    /// `image/png`, or a group: `image/*`.
    public var mimeType: String?

    /// Without the dot, the preferred one first: `["jpg", "jpeg"]`.
    public var fileExtensions: [String]

    public init(mimeType: String? = nil, fileExtensions: [String] = []) {
        self.mimeType = mimeType
        self.fileExtensions = fileExtensions
    }

    /// The well-known type with this MIME type, or one made of it.
    public init(mimeType: String) {
        let lowered = mimeType.lowercased()
        self = Self.known.first { $0.mimeType == lowered } ?? ContentType(mimeType: lowered, fileExtensions: [])
    }

    /// The well-known type with this extension, with or without its dot.
    public init?(filenameExtension: String) {
        var name = filenameExtension.lowercased()
        if name.utf8.first == UInt8(ascii: ".") {
            name.removeFirst()
        }
        guard !name.isEmpty, let known = Self.known.first(where: { $0.fileExtensions.contains(name) }) else {
            return nil
        }
        self = known
    }

    public var preferredFilenameExtension: String? {
        fileExtensions.first
    }

    /// Whether this is a group, such as `image/*`.
    public var isGroup: Bool {
        mimeType?.hasSuffix("/*") ?? false
    }

    /// Whether a file of this type is also of `type`: the same type, or
    /// one of the group `type` is.
    public func conforms(to type: ContentType) -> Bool {
        if self == type || type == .item {
            return true
        }
        guard type.isGroup, let group = type.mimeType, let mimeType else {
            return false
        }
        return mimeType.hasPrefix(group.dropLast())
    }

    /// The forms the `Documents` contract takes, as HTML's `accept` does:
    /// the MIME type, or each extension with its dot.
    public var wireForms: [String] {
        if let mimeType {
            return [mimeType]
        }
        return fileExtensions.map { "." + $0 }
    }

    /// What a picker is asked for. Asking for anything is asking for no
    /// type in particular.
    static func wireForms(_ types: [ContentType]) -> [String] {
        if types.contains(.item) {
            return []
        }
        var forms: [String] = []
        for form in types.flatMap({ $0.wireForms }) where !forms.contains(form) {
            forms.append(form)
        }
        return forms
    }
}

extension ContentType {

    // MARK: Groups

    /// Any file.
    public static let item = ContentType(mimeType: "*/*", fileExtensions: [])
    /// Any file: `UTType.data`.
    public static let data = item
    public static let image = ContentType(mimeType: "image/*", fileExtensions: [])
    public static let audio = ContentType(mimeType: "audio/*", fileExtensions: [])
    /// Video, with or without sound.
    public static let movie = ContentType(mimeType: "video/*", fileExtensions: [])
    public static let video = movie
    public static let text = ContentType(mimeType: "text/*", fileExtensions: [])
    /// A folder, as a document says its type is. Pick one with
    /// `DocumentPicker.openFolder`.
    public static let folder = ContentType(mimeType: "inode/directory", fileExtensions: [])

    // MARK: Images

    public static let png = ContentType(mimeType: "image/png", fileExtensions: ["png"])
    public static let jpeg = ContentType(mimeType: "image/jpeg", fileExtensions: ["jpg", "jpeg"])
    public static let gif = ContentType(mimeType: "image/gif", fileExtensions: ["gif"])
    public static let webP = ContentType(mimeType: "image/webp", fileExtensions: ["webp"])
    public static let heic = ContentType(mimeType: "image/heic", fileExtensions: ["heic"])
    public static let svg = ContentType(mimeType: "image/svg+xml", fileExtensions: ["svg"])

    // MARK: Sound and video

    public static let mp3 = ContentType(mimeType: "audio/mpeg", fileExtensions: ["mp3"])
    public static let mpeg4Audio = ContentType(mimeType: "audio/mp4", fileExtensions: ["m4a"])
    public static let wav = ContentType(mimeType: "audio/wav", fileExtensions: ["wav"])
    public static let mpeg4Movie = ContentType(mimeType: "video/mp4", fileExtensions: ["mp4", "m4v"])
    public static let quickTimeMovie = ContentType(mimeType: "video/quicktime", fileExtensions: ["mov"])

    // MARK: Text and data

    public static let plainText = ContentType(mimeType: "text/plain", fileExtensions: ["txt"])
    public static let html = ContentType(mimeType: "text/html", fileExtensions: ["html", "htm"])
    public static let commaSeparatedText = ContentType(mimeType: "text/csv", fileExtensions: ["csv"])
    public static let json = ContentType(mimeType: "application/json", fileExtensions: ["json"])
    public static let xml = ContentType(mimeType: "application/xml", fileExtensions: ["xml"])
    public static let pdf = ContentType(mimeType: "application/pdf", fileExtensions: ["pdf"])
    public static let zip = ContentType(mimeType: "application/zip", fileExtensions: ["zip"])

    // MARK: Other

    public static let vCard = ContentType(mimeType: "text/vcard", fileExtensions: ["vcf"])
    public static let calendarEvent = ContentType(mimeType: "text/calendar", fileExtensions: ["ics"])

    /// The types with a name here, for looking one up.
    static let known: [ContentType] = [
        .png, .jpeg, .gif, .webP, .heic, .svg,
        .mp3, .mpeg4Audio, .wav, .mpeg4Movie, .quickTimeMovie,
        .plainText, .html, .commaSeparatedText, .json, .xml, .pdf, .zip,
        .vCard, .calendarEvent,
        .image, .audio, .movie, .text, .folder, .item,
    ]
}
