import Foundation
import Testing
import DynamicFiles
import DynamicPhotos
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimePhotos

/// `HostPhotos` over a library in memory, driven from the guest's
/// `PhotoLibrary` through the runtime, with real files for what's added
/// and for originals.
///
/// Serialized: `HostPhotos`, `HostFiles` and the native runtime are shared.
@Suite(.serialized) final class RuntimePhotosTests {

    let root: URL

    let store: MemoryPhotoStore

    let library = PhotoLibrary.shared

    let files = DynamicFiles.FileManager()

    /// What the user answers when the system asks about a deletion.
    nonisolated(unsafe) var confirmsDeletion = true

    nonisolated(unsafe) var askedToDelete: [[String]] = []

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("RuntimePhotosTests-\(UUID().uuidString)")
        let container = root.appendingPathComponent("Container")
        store = MemoryPhotoStore(directory: root.appendingPathComponent("Originals").path)
        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .caches: container.appendingPathComponent("Caches").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostPhotos.reset()
        HostPhotos.store = store
        HostPhotos.access = .authorized
        HostPhotos.work = { $0() }
        HostPhotos.deliver = { $0() }
        HostPhotosModule.register(in: native)
        library.onChange(nil)
        let store = self.store
        HostPhotos.deleter = { [unowned self] identifiers, completion in
            askedToDelete.append(identifiers)
            guard confirmsDeletion else {
                completion(.failure(.cancelledByUser))
                return
            }
            do throws(PhotoLibraryError) {
                try store.remove(identifiers)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    deinit {
        HostPhotos.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    // MARK: Files

    /// The smallest PNG header that says a size.
    static func png(width: UInt32, height: UInt32) -> [UInt8] {
        func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8) + big(width) + big(height) + [8, 6, 0, 0, 0]
    }

    /// A JPEG's start, with a frame that says a size.
    static func jpeg(width: UInt16, height: UInt16) -> [UInt8] {
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let frame: [UInt8] = [0xFF, 0xC0, 0x00, 0x11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3]
        return [0xFF, 0xD8] + app0 + frame + [UInt8](repeating: 0, count: 12) + [0xFF, 0xD9]
    }

    static func mp4(_ brand: String = "isom") -> [UInt8] {
        [0, 0, 0, 24] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 2, 0] + Array("isomiso2".utf8) + [UInt8](repeating: 7, count: 40)
    }

    /// Writes one of the app's own files.
    func write(_ bytes: [UInt8], to file: FilePath) throws {
        let path = try HostFiles.path(of: file.directory.rawValue, path: file.path, writing: true)
        try Foundation.FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Helpers

    func failure<Value>(_ result: Result<Value, PhotoLibraryError>?) -> PhotoLibraryError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func add(photo file: FilePath) -> Result<PhotoAsset?, PhotoLibraryError>? {
        var result: Result<PhotoAsset?, PhotoLibraryError>?
        library.add(photo: file) { result = $0 }
        return result
    }

    func add(video file: FilePath) -> Result<PhotoAsset?, PhotoLibraryError>? {
        var result: Result<PhotoAsset?, PhotoLibraryError>?
        library.add(video: file) { result = $0 }
        return result
    }

    /// The asset an app that may read is told it made.
    func added(photo file: FilePath) throws -> PhotoAsset {
        let asset = try #require(add(photo: file)).get()
        return try #require(asset)
    }

    func added(video file: FilePath) throws -> PhotoAsset {
        let asset = try #require(add(video: file)).get()
        return try #require(asset)
    }

    func fetch(of kind: PhotoKind? = nil, in album: PhotoAlbum? = nil) -> Result<PhotoFetchResult, PhotoLibraryError>? {
        var result: Result<PhotoFetchResult, PhotoLibraryError>?
        library.assets(of: kind, in: album) { result = $0 }
        return result
    }

    func page(_ results: PhotoFetchResult, _ range: Range<Int>) -> Result<[PhotoAsset], PhotoLibraryError>? {
        var result: Result<[PhotoAsset], PhotoLibraryError>?
        results.assets(in: range) { result = $0 }
        return result
    }

    /// The identifiers of everything a fetch finds.
    func identifiers(of kind: PhotoKind? = nil, in album: PhotoAlbum? = nil) throws -> [String] {
        let results = try #require(fetch(of: kind, in: album)).get()
        return try #require(page(results, 0 ..< results.count)).get().map(\.id)
    }

    func file(for asset: PhotoAsset) -> Result<PhotoFile, PhotoLibraryError>? {
        var result: Result<PhotoFile, PhotoLibraryError>?
        library.file(for: asset) { result = $0 }
        return result
    }

    func delete(_ assets: [PhotoAsset]) -> Result<Void, PhotoLibraryError>? {
        var result: Result<Void, PhotoLibraryError>?
        library.delete(assets) { result = $0 }
        return result
    }

    func albums() throws -> [PhotoAlbum] {
        var result: Result<[PhotoAlbum], PhotoLibraryError>?
        library.albums { result = $0 }
        return try #require(result).get()
    }

    func contents(_ file: FilePath) -> Result<[UInt8], FileError>? {
        var result: Result<[UInt8], FileError>?
        files.contents(at: file) { result = $0 }
        return result
    }

    /// A trip's album, three photos and a video, the oldest first made.
    @discardableResult
    func fill() -> (trip: PhotoAlbum, assets: [PhotoAsset]) {
        let trip = store.makeAlbum("Trip")
        let assets = [
            store.insert(Self.jpeg(width: 4032, height: 3024), name: "IMG_0001.JPG", creationDate: 1000, width: 4032, height: 3024, albums: [trip.id]),
            store.insert(Self.png(width: 1170, height: 2532), contentType: "image/png", name: "Screenshot.png", creationDate: 2000, width: 1170, height: 2532, isFavorite: true),
            store.insert(Self.mp4("qt  "), kind: .video, contentType: "video/quicktime", name: "IMG_0002.MOV", creationDate: 3000, width: 1920, height: 1080, duration: 12.5, albums: [trip.id], isInCloud: true),
            store.insert(Self.jpeg(width: 3024, height: 4032), name: "IMG_0003.JPG", creationDate: 4000, width: 3024, height: 4032, albums: [trip.id]),
        ]
        return (trip, assets)
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostPhotosModule.contracts.map(\.name) == [
            "org.pureswift.photos.Photos", "org.pureswift.photos.Results", "org.pureswift.photos.File",
            "org.pureswift.photos.Callback", "org.pureswift.photos.Delegate",
        ])
        #expect(HostPhotos.shared() === HostPhotos.shared())
        let permission = HostPhotosModule.permissionProviders()[.photoLibrary]
        #expect(permission?.status() == .granted)
        HostPhotos.access = .limited
        #expect(permission?.status() == .limited)
        HostPhotos.access = .denied
        #expect(permission?.status() == .denied)
        // Adding is all an app that only adds asked for; for one that
        // browses, the question hasn't been put.
        HostPhotos.access = .addOnly
        #expect(permission?.status() == .notDetermined)
        HostPhotos.allowsReading = false
        #expect(permission?.status() == .granted)
        HostPhotos.store = nil
        #expect(permission?.status() == .unavailable)
    }

    // MARK: Formats

    @Test func aFileIsKnownByItsFirstBytes() {
        func format(_ bytes: [UInt8]) -> String? { PhotoFileFormat.detect(bytes)?.contentType }
        #expect(format(Self.jpeg(width: 1, height: 1)) == "image/jpeg")
        #expect(format(Self.png(width: 1, height: 1)) == "image/png")
        #expect(format(Self.mp4("heic")) == "image/heic" && format(Self.mp4("mif1")) == "image/heif")
        #expect(format(Self.mp4("isom")) == "video/mp4" && format(Self.mp4("mp42")) == "video/mp4")
        #expect(format(Self.mp4("qt  ")) == "video/quicktime")
        #expect(format([0, 0, 0, 8] + Array("wide".utf8) + [0, 0, 0, 0] + Array("mdat".utf8)) == "video/quicktime")
        #expect(PhotoFileFormat.detect(Self.mp4("heic"))?.kind == .image && PhotoFileFormat.detect(Self.mp4())?.kind == .video)
        // Sound alone, text, and what's too short to say.
        #expect(format(Self.mp4("M4A ")) == nil)
        #expect(format(Array("GIF89a and the rest".utf8)) == nil)
        #expect(format(Array("hello, this is text".utf8)) == nil)
        #expect(format([0xFF, 0xD8]) == nil && format([]) == nil && format([0, 0, 0, 24] + Array("ftyp".utf8)) == nil)
        #expect(PhotoFileFormat.detect(fileAt: root.appendingPathComponent("missing.jpg").path) == nil)
    }

    @Test func aPicturesSizeIsInItsHeader() throws {
        let png = try #require(PhotoFileFormat.pixelSize(of: Self.png(width: 1170, height: 2532)))
        #expect(png == (1170, 2532))
        let jpeg = try #require(PhotoFileFormat.pixelSize(of: Self.jpeg(width: 4032, height: 3024)))
        #expect(jpeg == (4032, 3024))
        #expect(PhotoFileFormat.pixelSize(of: Self.mp4()) == nil)
        #expect(PhotoFileFormat.pixelSize(of: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0, 0]) == nil, "no frame in it")
        #expect(PhotoFileFormat.pixelSize(of: [0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF]) == nil, "a segment longer than the file")
    }

    // MARK: Access

    @Test func withoutAStoreThereIsNoLibrary() throws {
        HostPhotos.store = nil
        #expect(library.access == .unavailable)
        var granted: PhotoLibraryAccess?
        library.requestAccess { granted = $0 }
        #expect(granted == .unavailable)
        try write(Self.jpeg(width: 4, height: 4), to: .caches / "shot.jpg")
        #expect(failure(add(photo: .caches / "shot.jpg")) == .unavailable)
        #expect(failure(fetch()) == .unavailable)
        #expect(failure(delete([PhotoAsset(id: "x")])) == .unavailable)
        var listed: Result<[PhotoAlbum], PhotoLibraryError>?
        library.albums { listed = $0 }
        #expect(failure(listed) == .unavailable)
    }

    @Test func theUserIsAskedOnce() {
        HostPhotos.access = .notDetermined
        var asked = 0
        HostPhotos.requester = { completion in
            asked += 1
            completion(.limited)
            // A platform that answers twice is heard once.
            completion(.denied)
        }
        #expect(library.access == .notDetermined && asked == 0, "reading the access never asks")
        var granted: [PhotoLibraryAccess] = []
        library.requestAccess { granted.append($0) }
        library.requestAccess { granted.append($0) }
        #expect(granted == [.limited, .limited] && asked == 1)
        #expect(library.access == .limited)

        HostPhotos.access = .denied
        library.requestAccess { granted.append($0) }
        #expect(granted.last == .denied && asked == 1, "a decision isn't asked about again")
        HostPhotos.access = .notDetermined
        HostPhotos.requester = nil
        library.requestAccess { granted.append($0) }
        #expect(granted.last == .notDetermined, "a host with no question to put says where things stand")
    }

    @Test func aHostThatNeedsNoLeaveToAddStillAsksToRead() {
        // Android adds without a permission, and reads with one.
        HostPhotos.access = .addOnly
        var asked = 0
        HostPhotos.requester = { completion in
            asked += 1
            completion(.authorized)
        }
        #expect(library.access == .addOnly)
        var granted: PhotoLibraryAccess?
        library.requestAccess { granted = $0 }
        #expect(granted == .authorized && asked == 1)

        // An app that only adds has all it declared: nothing to ask.
        HostPhotos.access = .addOnly
        HostPhotos.allowsReading = false
        library.requestAccess { granted = $0 }
        #expect(granted == .addOnly && asked == 1)
    }

    @Test func anAppThatDeclaredAddingNeverReads() throws {
        fill()
        HostPhotos.allowsReading = false
        // Whatever the user granted.
        HostPhotos.access = .authorized
        #expect(library.access == .addOnly)
        try write(Self.jpeg(width: 640, height: 480), to: .caches / "shot.jpg")
        let added = try #require(add(photo: .caches / "shot.jpg")).get()
        #expect(added == nil, "not even the identifier of what it added")
        #expect(store.allAssets.count == 5)

        #expect(failure(fetch()) == .notAuthorized)
        var found: Result<PhotoAsset?, PhotoLibraryError>?
        library.asset(withID: store.allAssets[0].id) { found = $0 }
        #expect(failure(found) == .notAuthorized)
        var listed: Result<[PhotoAlbum], PhotoLibraryError>?
        library.albums { listed = $0 }
        #expect(failure(listed) == .notAuthorized)
        #expect(failure(file(for: store.allAssets[0])) == .notAuthorized)
        #expect(failure(delete([store.allAssets[0]])) == .notAuthorized)
        #expect(askedToDelete.isEmpty)
    }

    @Test func withoutLeaveNothingIsDone() throws {
        fill()
        try write(Self.jpeg(width: 4, height: 4), to: .caches / "shot.jpg")
        for access in [PhotoLibraryAccess.notDetermined, .denied, .restricted] {
            HostPhotos.access = access
            #expect(failure(add(photo: .caches / "shot.jpg")) == .notAuthorized, "\(access)")
            #expect(failure(fetch()) == .notAuthorized, "\(access)")
        }
        #expect(store.allAssets.count == 4)
        // A fetch made with leave reads nothing once the leave has gone.
        HostPhotos.access = .authorized
        let results = try #require(fetch()).get()
        HostPhotos.access = .denied
        #expect(failure(page(results, 0 ..< 4)) == .notAuthorized)
    }

    // MARK: Adding

    @Test func aPhotoIsCopiedIn() throws {
        store.now = { 5000 }
        try write(Self.jpeg(width: 4032, height: 3024), to: .caches / "shot.jpg")
        let asset = try added(photo: .caches / "shot.jpg")
        #expect(asset.kind == .image && asset.width == 4032 && asset.height == 3024)
        #expect(asset.creationDate == 5000 && asset.duration == 0 && !asset.isFavorite)
        #expect(try identifiers() == [asset.id])
        // The app keeps its own.
        #expect(try #require(contents(.caches / "shot.jpg")).get() == Self.jpeg(width: 4032, height: 3024))

        try write(Self.png(width: 20, height: 10), to: .documents / "art" / "icon.png")
        let png = try added(photo: .documents / "art" / "icon.png")
        #expect(png.width == 20 && png.height == 10)
        try write(Self.mp4(), to: .caches / "clip.mp4")
        let video = try added(video: .caches / "clip.mp4")
        #expect(video.kind == .video)
        #expect(store.allAssets.count == 3)
    }

    @Test func onlyAPhotoOrAVideoIsTaken() throws {
        try write(Array("just some notes".utf8), to: .caches / "notes.jpg")
        try write(Self.mp4(), to: .caches / "clip.mp4")
        try write(Self.jpeg(width: 4, height: 4), to: .caches / "shot.jpg")
        #expect(failure(add(photo: .caches / "notes.jpg")) == .invalidData, "whatever it's called")
        #expect(failure(add(photo: .caches / "clip.mp4")) == .invalidData, "a video isn't a photo")
        #expect(failure(add(video: .caches / "shot.jpg")) == .invalidData)
        #expect(failure(add(photo: .caches / "missing.jpg")) == .notFound)
        try Foundation.FileManager.default.createDirectory(atPath: try HostFiles.path(of: FileDirectory.caches.rawValue, path: "folder", writing: true), withIntermediateDirectories: true)
        #expect(failure(add(photo: .caches / "folder")) == .notFound)
        #expect(failure(add(photo: FilePath(FileDirectory(rawValue: 999)) / "shot.jpg")) == .notAuthorized, "a place the app was never given")
        #expect(store.allAssets.isEmpty)

        var failed: PhotoLibraryError?
        PhotosProxy.shared().add(FileDirectory.caches.rawValue, path: "shot.jpg", kind: 7, callback: TestCallback { failed = $0 })
        #expect(failed == .invalidData, "a kind from a newer guest")
    }

    // MARK: Browsing

    @Test func aFetchIsNewestFirst() throws {
        let (trip, assets) = fill()
        #expect(try identifiers() == [assets[3].id, assets[2].id, assets[1].id, assets[0].id])
        #expect(try identifiers(of: .video) == [assets[2].id])
        #expect(try identifiers(of: .image) == [assets[3].id, assets[1].id, assets[0].id])
        #expect(try identifiers(in: trip) == [assets[3].id, assets[2].id, assets[0].id])
        #expect(try identifiers(of: .image, in: trip) == [assets[3].id, assets[0].id])
        #expect(failure(fetch(in: PhotoAlbum(id: "album-99", title: "Gone"))) == .notFound)

        // Made at the same moment: the later one first.
        let twin = store.insert(Self.jpeg(width: 1, height: 1), creationDate: 4000)
        #expect(try identifiers().prefix(2) == [twin.id, assets[3].id])
    }

    @Test func aPageIsReadAsItsAskedFor() throws {
        let (_, assets) = fill()
        let results = try #require(fetch()).get()
        #expect(results.count == 4)
        let first = try #require(page(results, 0 ..< 2)).get()
        #expect(first == [assets[3], assets[2]])
        #expect(first[1].duration == 12.5 && first[1].kind == .video)
        let rest = try #require(page(results, 2 ..< 10)).get()
        #expect(rest == [assets[1], assets[0]])
        #expect(rest[0].isFavorite && rest[0].width == 1170)
        #expect(try #require(page(results, 4 ..< 9)).get().isEmpty)
    }

    @Test func aFetchIsThePictureOfWhenItWasMade() throws {
        let (_, assets) = fill()
        let results = try #require(fetch()).get()
        let newer = store.insert(Self.jpeg(width: 1, height: 1), creationDate: 9000)
        try store.remove([assets[2].id])
        #expect(results.count == 4, "it doesn't change once made")
        let all = try #require(page(results, 0 ..< 4)).get()
        #expect(all.map(\.id) == [assets[3].id, assets[1].id, assets[0].id], "one that has gone since is left out")
        #expect(try identifiers().first == newer.id, "after a change, fetch again")
    }

    @Test func oneAssetIsFoundByItsIdentifier() throws {
        let (_, assets) = fill()
        var found: Result<PhotoAsset?, PhotoLibraryError>?
        library.asset(withID: assets[1].id) { found = $0 }
        #expect(try #require(found).get() == assets[1])
        library.asset(withID: "asset-404") { found = $0 }
        #expect(try #require(found).get() == nil)
    }

    @Test func albumsAreTheUsersAndTheSystems() throws {
        fill()
        store.makeAlbum("Empty")
        let albums = try albums()
        #expect(albums.map(\.title) == ["Trip", "Empty", "Favourites", "Videos"])
        #expect(albums.map(\.count) == [3, 0, 1, 1])
        #expect(albums.map(\.kind) == [.user, .user, .smart, .smart])
        #expect(try identifiers(in: albums[2]).count == 1 && identifiers(in: albums[3]).count == 1)
    }

    @Test func withLimitedAccessTheLibraryIsWhatTheUserChose() throws {
        let (trip, assets) = fill()
        HostPhotos.access = .limited
        store.chosen = [assets[0].id, assets[1].id]
        #expect(try identifiers() == [assets[1].id, assets[0].id])
        #expect(try identifiers(in: trip) == [assets[0].id])
        #expect(try albums().map(\.count) == [1, 1, 0], "nothing is said of the others")
        var found: Result<PhotoAsset?, PhotoLibraryError>?
        library.asset(withID: assets[3].id) { found = $0 }
        #expect(try #require(found).get() == nil)
        #expect(failure(file(for: assets[3])) == .notFound)
        #expect(failure(delete([assets[0], assets[3]])) == .notFound, "all of them or none")
        #expect(store.allAssets.count == 4)

        // What the app adds is among them.
        try write(Self.jpeg(width: 8, height: 8), to: .caches / "shot.jpg")
        let added = try added(photo: .caches / "shot.jpg")
        #expect(try identifiers().contains(added.id))
    }

    // MARK: Originals

    @Test func anOriginalIsAFileFilesReaches() throws {
        let (_, assets) = fill()
        do {
            let original = try #require(file(for: assets[0])).get()
            #expect(original.contentType == "image/jpeg" && original.name == "IMG_0001.JPG")
            #expect(original.path.directory.rawValue >= 256, "a grant, as a picked document is")
            #expect(try #require(contents(original.path)).get() == Self.jpeg(width: 4032, height: 3024), "the original, unchanged")
            #expect(store.heldOriginals.count == 1)

            // Read-only: a photo is changed by adding a new one.
            var written: Result<Void, FileError>?
            files.write([1, 2, 3], to: original.path) { written = $0 }
            if case .failure(let error)? = written {
                #expect(error == .readOnly)
            } else {
                Issue.record("an original was written over")
            }

            // Each asking is an access of its own.
            let again = try #require(file(for: assets[0])).get()
            #expect(again.path != original.path && store.heldOriginals.count == 2)
        }
        #expect(store.heldOriginals.isEmpty, "the host removes its copies when the guest lets go")
        let left = (try? Foundation.FileManager.default.contentsOfDirectory(atPath: store.directory)) ?? []
        #expect(left.isEmpty)
    }

    @Test func aPathKeptPastItsFileIsRefused() throws {
        let (_, assets) = fill()
        var kept: FilePath?
        do {
            let original = try #require(file(for: assets[1])).get()
            kept = original.path
            #expect(try #require(contents(original.path)).get().starts(with: [0x89, 0x50]))
        }
        if case .failure(let error)? = contents(try #require(kept)) {
            #expect(error == .notPermitted)
        } else {
            Issue.record("a released original was read")
        }
    }

    @Test func anOriginalInTheCloudNeedsTheNetwork() throws {
        let (_, assets) = fill()
        store.isOnline = false
        #expect(failure(file(for: assets[2])) == .unavailable)
        #expect(try #require(file(for: assets[0])).get().contentType == "image/jpeg", "one that's here is here")
        store.isOnline = true
        let video = try #require(file(for: assets[2])).get()
        #expect(video.contentType == "video/quicktime" && video.name == "IMG_0002.MOV")
        #expect(failure(file(for: PhotoAsset(id: "asset-404"))) == .notFound)
    }

    // MARK: Deleting

    @Test func deletingAsksTheUser() throws {
        let (_, assets) = fill()
        confirmsDeletion = false
        #expect(failure(delete([assets[0], assets[1]])) == .cancelledByUser)
        #expect(askedToDelete == [[assets[0].id, assets[1].id]] && store.allAssets.count == 4)

        confirmsDeletion = true
        #expect(failure(delete([assets[0], assets[1]])) == nil)
        #expect(try identifiers() == [assets[3].id, assets[2].id])
        #expect(failure(delete([assets[0]])) == .notFound, "already gone")

        // Nothing to delete is nothing to ask.
        #expect(failure(delete([])) == nil && askedToDelete.count == 3)

        HostPhotos.deleter = { _, completion in
            completion(.success(()))
            completion(.failure(.unknown))
        }
        var answers = 0
        library.delete([assets[3]]) { _ in answers += 1 }
        #expect(answers == 1, "a platform that answers twice is heard once")
        HostPhotos.deleter = nil
        #expect(failure(delete([assets[3]])) == .unavailable, "a host with no way to ask doesn't delete")
    }

    // MARK: Changes

    @Test func aBurstOfChangesIsOneReport() throws {
        nonisolated(unsafe) var queued: [@Sendable () -> Void] = []
        var heard = 0
        library.onChange { heard += 1 }
        HostPhotos.deliver = { queued.append($0) }
        HostPhotos.libraryChanged()
        HostPhotos.libraryChanged()
        HostPhotos.libraryChanged()
        #expect(heard == 0 && queued.count == 1)
        queued.removeFirst()()
        #expect(heard == 1)
        HostPhotos.libraryChanged()
        queued.removeFirst()()
        #expect(heard == 2)

        // This app's own changes are reported too.
        HostPhotos.deliver = { $0() }
        try write(Self.jpeg(width: 4, height: 4), to: .caches / "shot.jpg")
        let added = try added(photo: .caches / "shot.jpg")
        #expect(heard == 3)
        #expect(failure(delete([added])) == nil)
        #expect(heard == 4)
        confirmsDeletion = false
        _ = delete([added])
        #expect(heard == 4, "a deletion refused changed nothing")

        library.onChange(nil)
        HostPhotos.libraryChanged()
        #expect(heard == 4)
    }
}

/// A callback that only hears a failure.
final class TestCallback: PhotoCallback {

    let failed: (PhotoLibraryError?) -> Void

    init(_ failed: @escaping (PhotoLibraryError?) -> Void) {
        self.failed = failed
    }

    func didComplete() { failed(nil) }
    func didChangeAccess(_ access: Int32) { failed(nil) }
    func didAdd(_ fields: [String]) { failed(nil) }
    func didFetch(_ results: any PhotoResults) { failed(nil) }
    func didListAssets(_ fields: [String]) { failed(nil) }
    func didFindAsset(_ fields: [String]) { failed(nil) }
    func didListAlbums(_ fields: [String]) { failed(nil) }
    func didOpenFile(_ file: any PhotoFileGrant) { failed(nil) }
    func didFail(_ error: Int32) { failed(PhotoLibraryError(rawValue: error)) }
}
