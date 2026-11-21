import DynamicPhotos
import Foundation

/// A photo library in memory, over files it's given: for tests. It isn't a
/// host's default, since it's nobody's photos. It behaves as a `PhotoStore`
/// must: newest first, an original written out for as long as it's held,
/// the photos the user chose and no others, and an original in the cloud
/// that can't be had offline.
public final class MemoryPhotoStore: PhotoStore, @unchecked Sendable {

    private struct Item {
        var asset: PhotoAsset
        var data: [UInt8]
        var contentType: String
        var name: String?
        var albums: [String]
        /// Kept in the cloud: its original needs a download.
        var isInCloud: Bool
        /// Its place among assets made at the same moment.
        var order: Int
    }

    private let lock = NSLock()

    private var items: [Item] = []

    private var userAlbums: [(id: String, title: String)] = []

    private var nextNumber = 1

    private var held: [String: Int] = [:]

    /// Where originals are written while a guest holds them.
    public let directory: String

    /// The moment a photo is added: milliseconds since 1970.
    public var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    /// With limited access, the photos the user chose. `nil` is all of
    /// them. What the app adds joins them.
    public var chosen: Set<String>? {
        get { lock.withLock { chosenIDs } }
        set { lock.withLock { chosenIDs = newValue } }
    }

    private var chosenIDs: Set<String>?

    /// Whether an original kept in the cloud can be fetched.
    public var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    private var online = true

    /// The originals written out and not yet released.
    public var heldOriginals: [String] {
        lock.withLock { held.keys.sorted() }
    }

    public init(directory: String) {
        self.directory = directory
    }

    private func locked<Value>(_ body: () throws(PhotoLibraryError) -> Value) throws(PhotoLibraryError) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: For a test

    /// Puts a photo or a video in the library, as the camera or a sync
    /// would, and gives its asset.
    @discardableResult
    public func insert(
        _ data: [UInt8],
        kind: PhotoKind = .image,
        contentType: String = "image/jpeg",
        name: String? = nil,
        creationDate: Int64,
        width: Int = 0,
        height: Int = 0,
        duration: Double = 0,
        isFavorite: Bool = false,
        albums: [String] = [],
        isInCloud: Bool = false
    ) -> PhotoAsset {
        lock.withLock {
            let asset = PhotoAsset(
                id: "asset-\(nextNumber)", kind: kind, creationDate: creationDate,
                width: width, height: height, duration: duration, isFavorite: isFavorite
            )
            items.append(Item(asset: asset, data: data, contentType: contentType, name: name, albums: albums, isInCloud: isInCloud, order: nextNumber))
            nextNumber += 1
            return asset
        }
    }

    /// An album the user made. Photos are put in it as they're inserted.
    @discardableResult
    public func makeAlbum(_ title: String) -> PhotoAlbum {
        lock.withLock {
            let id = "album-\(userAlbums.count + 1)"
            userAlbums.append((id, title))
            return PhotoAlbum(id: id, title: title, count: 0, kind: .user)
        }
    }

    /// Deletes assets, as the user confirming a deletion does: all of
    /// them, or none if one isn't there.
    public func remove(_ identifiers: [String]) throws(PhotoLibraryError) {
        try locked { () throws(PhotoLibraryError) in
            let visible = Set(visibleItems.map { $0.asset.id })
            guard identifiers.allSatisfy({ visible.contains($0) }) else {
                throw .notFound
            }
            items.removeAll { identifiers.contains($0.asset.id) }
        }
    }

    /// Everything in the library, newest first, whatever the user chose.
    public var allAssets: [PhotoAsset] {
        lock.withLock { Self.newestFirst(items).map { $0.asset } }
    }

    // MARK: PhotoStore

    private var visibleItems: [Item] {
        guard let chosenIDs else { return items }
        return items.filter { chosenIDs.contains($0.asset.id) }
    }

    private static func newestFirst(_ items: [Item]) -> [Item] {
        items.sorted { ($0.asset.creationDate, $0.order) > ($1.asset.creationDate, $1.order) }
    }

    /// The albums the system keeps here, with what's in each.
    private static let smartAlbums: [(id: String, title: String, holds: @Sendable (PhotoAsset) -> Bool)] = [
        ("smart-favorites", "Favourites", { $0.isFavorite }),
        ("smart-videos", "Videos", { $0.kind == .video }),
    ]

    public func add(fileAt path: String, kind: PhotoKind) throws(PhotoLibraryError) -> PhotoAsset {
        guard let contents = FileManager.default.contents(atPath: path) else {
            throw .notFound
        }
        let data = [UInt8](contents)
        guard let format = PhotoFileFormat.detect(Array(data.prefix(PhotoFileFormat.headerLength))), format.kind == kind else {
            throw .invalidData
        }
        let size = PhotoFileFormat.pixelSize(of: data)
        let name = path.split(separator: "/").last.map(String.init)
        let asset = insert(
            data, kind: kind, contentType: format.contentType, name: name, creationDate: now(),
            width: size?.width ?? 0, height: size?.height ?? 0
        )
        lock.withLock {
            // What the app adds is among the photos it sees.
            _ = chosenIDs?.insert(asset.id)
        }
        return asset
    }

    public func identifiers(of kind: PhotoKind?, in album: String?) throws(PhotoLibraryError) -> [String] {
        try locked { () throws(PhotoLibraryError) in
            var found = visibleItems
            if let album {
                if let smart = Self.smartAlbums.first(where: { $0.id == album }) {
                    found = found.filter { smart.holds($0.asset) }
                } else if userAlbums.contains(where: { $0.id == album }) {
                    found = found.filter { $0.albums.contains(album) }
                } else {
                    throw .notFound
                }
            }
            if let kind {
                found = found.filter { $0.asset.kind == kind }
            }
            return Self.newestFirst(found).map { $0.asset.id }
        }
    }

    public func assets(withIDs identifiers: [String]) throws(PhotoLibraryError) -> [PhotoAsset] {
        lock.withLock {
            visibleItems.filter { identifiers.contains($0.asset.id) }.map { $0.asset }
        }
    }

    public func albums() throws(PhotoLibraryError) -> [PhotoAlbum] {
        lock.withLock {
            let visible = visibleItems
            var albums = userAlbums.map { album in
                PhotoAlbum(id: album.id, title: album.title, count: visible.filter { $0.albums.contains(album.id) }.count, kind: .user)
            }
            for smart in Self.smartAlbums {
                albums.append(PhotoAlbum(id: smart.id, title: smart.title, count: visible.filter { smart.holds($0.asset) }.count, kind: .smart))
            }
            return albums
        }
    }

    public func original(of identifier: String) throws(PhotoLibraryError) -> HostPhotoOriginal {
        let (item, number): (Item, Int) = try locked { () throws(PhotoLibraryError) in
            guard let item = visibleItems.first(where: { $0.asset.id == identifier }) else {
                throw .notFound
            }
            guard !item.isInCloud || online else {
                throw .unavailable
            }
            nextNumber += 1
            return (item, nextNumber)
        }
        // A copy of its own for each asking, as a host exporting one makes.
        let name = item.name ?? identifier
        let folder = directory + "/original-\(number)"
        let path = folder + "/" + name
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data(item.data).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .unavailable
        }
        lock.withLock { held[path] = 1 }
        return HostPhotoOriginal(path: path, contentType: item.contentType, name: item.name)
    }

    public func release(_ original: HostPhotoOriginal) {
        lock.withLock { held[original.path] = nil }
        let folder = String(original.path[..<(original.path.lastIndex(of: "/") ?? original.path.endIndex)])
        try? FileManager.default.removeItem(atPath: folder)
    }
}
