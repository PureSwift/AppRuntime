import DynamicPhotos
import Foundation

/// What a file is, by its first bytes: how a host tells a photo from a
/// video, whatever the file is called.
public struct PhotoFileFormat: Equatable, Sendable {

    public var kind: PhotoKind

    /// A MIME type.
    public var contentType: String

    public init(kind: PhotoKind, contentType: String) {
        self.kind = kind
        self.contentType = contentType
    }

    /// How many of a file's first bytes `detect` looks at.
    public static let headerLength = 16

    /// A JPEG, PNG or HEIC image, or an MP4 or QuickTime video: what a
    /// library takes. `nil` for anything else.
    public static func detect(_ header: [UInt8]) -> PhotoFileFormat? {
        if header.starts(with: [0xFF, 0xD8, 0xFF]) {
            return PhotoFileFormat(kind: .image, contentType: "image/jpeg")
        }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return PhotoFileFormat(kind: .image, contentType: "image/png")
        }
        guard header.count >= 12 else { return nil }
        // An ISO media file: a box's size, then its name.
        let box = String(decoding: header[4 ..< 8], as: UTF8.self)
        if box == "ftyp" {
            let brand = String(decoding: header[8 ..< 12], as: UTF8.self)
            switch brand {
            case "heic", "heix", "heim", "heis", "hevc", "hevx":
                return PhotoFileFormat(kind: .image, contentType: "image/heic")
            case "mif1", "msf1":
                return PhotoFileFormat(kind: .image, contentType: "image/heif")
            case "qt  ":
                return PhotoFileFormat(kind: .video, contentType: "video/quicktime")
            case "M4A ", "M4B ", "avif", "avis":
                // Sound alone, and an image format a library needn't take.
                return nil
            default:
                return PhotoFileFormat(kind: .video, contentType: "video/mp4")
            }
        }
        // A QuickTime file from before `ftyp`.
        if ["moov", "mdat", "wide", "free", "skip"].contains(box) {
            return PhotoFileFormat(kind: .video, contentType: "video/quicktime")
        }
        return nil
    }

    /// The format of the file at an absolute path; `nil` when it can't be
    /// read, or isn't one a library takes.
    public static func detect(fileAt path: String) -> PhotoFileFormat? {
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        var header = [UInt8](repeating: 0, count: headerLength)
        let read = fread(&header, 1, headerLength, file)
        return detect(Array(header.prefix(read)))
    }

    /// A PNG's or a JPEG's size in pixels, as stored: what a library in
    /// memory says of a picture it was given. `nil` for anything else.
    public static func pixelSize(of data: [UInt8]) -> (width: Int, height: Int)? {
        func big(_ offset: Int, _ length: Int) -> Int {
            data[offset ..< offset + length].reduce(0) { $0 << 8 | Int($1) }
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]), data.count >= 24 {
            return (big(16, 4), big(20, 4))
        }
        guard data.starts(with: [0xFF, 0xD8]) else { return nil }
        var index = 2
        while index + 9 < data.count, data[index] == 0xFF {
            let marker = data[index + 1]
            // A start of frame, which isn't a table or an arithmetic one.
            if (0xC0 ... 0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                return (big(index + 7, 2), big(index + 5, 2))
            }
            index += 2 + big(index + 2, 2)
        }
        return nil
    }
}
