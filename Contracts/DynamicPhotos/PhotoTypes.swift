/// Guest-side names for what the `Photos` contract carries.

/// Whether the app may use the user's photos.
public enum PhotoLibraryAccess: Int32, Sendable {

    /// The user hasn't been asked.
    case notDetermined = 0

    /// Parental controls or device management prevent access.
    case restricted = 1

    /// The user refused, or the manifest doesn't declare `.photoLibrary`.
    case denied = 2

    /// The whole library.
    case authorized = 3

    /// The photos the user chose, and what the app adds.
    case limited = 4

    /// This host has no photo library.
    case unavailable = 5

    /// Adding, and reading nothing: all the manifest declares, or all the
    /// user has been asked for yet.
    case addOnly = 6

    /// Whether the library can be browsed at all.
    public var allowsReading: Bool {
        self == .authorized || self == .limited
    }

    /// Whether a photo can be added.
    public var allowsAdding: Bool {
        allowsReading || self == .addOnly
    }
}

/// A still picture or a moving one.
public enum PhotoKind: Int32, Sendable {

    case image = 1

    case video = 2
}

/// Why a photo library call failed.
public enum PhotoLibraryError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The operation may
    /// still happen. Hosts never send it.
    case cancelled = 1

    /// No access, or not enough for this call.
    case notAuthorized = 2

    /// This host has no library, or an original can't be fetched now.
    case unavailable = 3

    /// The asset, the album or the file is gone.
    case notFound = 4

    /// Not a photo or a video the library takes.
    case invalidData = 5

    /// The user refused a deletion.
    case cancelledByUser = 6
}

/// One photo or video in the library. A value: what the library said of
/// it when it was read.
public struct PhotoAsset: Identifiable, Equatable, Hashable, Sendable {

    /// The library's identifier for it. It lasts: an app may keep it.
    public var id: String

    public var kind: PhotoKind

    /// Milliseconds since 1970.
    public var creationDate: Int64

    /// Pixels, upright.
    public var width: Int

    public var height: Int

    /// Seconds; 0 for an image.
    public var duration: Double

    public var isFavorite: Bool

    public init(
        id: String,
        kind: PhotoKind = .image,
        creationDate: Int64 = 0,
        width: Int = 0,
        height: Int = 0,
        duration: Double = 0,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.width = width
        self.height = height
        self.duration = duration
        self.isFavorite = isFavorite
    }
}

extension PhotoAsset {

    /// How many strings an asset crosses as.
    public static let fieldCount = 7

    /// The asset as the contract carries it.
    public var fields: [String] {
        [
            id, String(kind.rawValue), String(creationDate), String(width), String(height),
            String(milliseconds), isFavorite ? "1" : "0",
        ]
    }

    /// The duration as the contract carries it; 0 for one that isn't a
    /// length of time.
    private var milliseconds: Int64 {
        guard duration.isFinite, duration > 0, duration < 1_000_000_000 else { return 0 }
        return Int64(duration * 1000 + 0.5)
    }

    /// Assets as the contract carries them: seven strings for each.
    public static func fields(_ assets: [PhotoAsset]) -> [String] {
        var fields: [String] = []
        fields.reserveCapacity(assets.count * fieldCount)
        for asset in assets {
            fields += asset.fields
        }
        return fields
    }

    /// Whole sevens are read; a remainder is left out, and so is an asset
    /// with no identifier.
    public static func assets(_ fields: [String]) -> [PhotoAsset] {
        var result: [PhotoAsset] = []
        var index = 0
        while index + fieldCount <= fields.count {
            defer { index += fieldCount }
            guard !fields[index].isEmpty else { continue }
            result.append(PhotoAsset(
                id: fields[index],
                // A kind from a newer host is still something to show.
                kind: PhotoKind(rawValue: Int32(fields[index + 1]) ?? 0) ?? .image,
                creationDate: Int64(fields[index + 2]) ?? 0,
                width: max(Int(fields[index + 3]) ?? 0, 0),
                height: max(Int(fields[index + 4]) ?? 0, 0),
                duration: Double(max(Int64(fields[index + 5]) ?? 0, 0)) / 1000,
                isFavorite: fields[index + 6] == "1"
            ))
        }
        return result
    }
}

/// A collection of the library's photos. Read, and not made or changed.
public struct PhotoAlbum: Identifiable, Equatable, Hashable, Sendable {

    public enum Kind: Int32, Sendable {

        /// One the user made.
        case user = 1

        /// One the system keeps: Favourites, Videos, Screenshots.
        case smart = 2
    }

    public var id: String

    public var title: String

    /// How many it holds.
    public var count: Int

    public var kind: Kind

    public init(id: String, title: String, count: Int = 0, kind: Kind = .user) {
        self.id = id
        self.title = title
        self.count = count
        self.kind = kind
    }
}

extension PhotoAlbum {

    public static let fieldCount = 4

    /// Albums as the contract carries them: four strings for each.
    public static func fields(_ albums: [PhotoAlbum]) -> [String] {
        var fields: [String] = []
        for album in albums {
            fields += [album.id, album.title, String(album.count), String(album.kind.rawValue)]
        }
        return fields
    }

    /// Whole fours are read; a remainder is left out.
    public static func albums(_ fields: [String]) -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []
        var index = 0
        while index + fieldCount <= fields.count {
            defer { index += fieldCount }
            guard !fields[index].isEmpty else { continue }
            result.append(PhotoAlbum(
                id: fields[index],
                title: fields[index + 1],
                count: max(Int(fields[index + 2]) ?? 0, 0),
                // A kind from a newer host isn't one the user made.
                kind: Kind(rawValue: Int32(fields[index + 3]) ?? 0) ?? .smart
            ))
        }
        return result
    }
}

/// How a `PhotoView` puts a picture in its space.
public enum PhotoScaling: String, Sendable {

    /// The space filled, the picture cropped.
    case fill

    /// All of it, inside the space.
    case fit
}
