import Testing
import DynamicFiles
import DynamicPhotos
import DynamicRuntime
import DynamicSwiftUI
import DynamicUI
import RuntimeCore
import RuntimeNative

/// A fetch the test's host hands out, which writes down the pages asked
/// for.
final class ScriptedPhotoResults: PhotoResults {

    nonisolated(unsafe) static var released = 0

    let total: Int32

    var pages: [String] = []

    var callbacks: [any PhotoCallback] = []

    init(_ total: Int32) {
        self.total = total
    }

    deinit {
        Self.released += 1
    }

    func count() -> Int32 { total }

    func assets(_ start: Int32, count: Int32, callback: any PhotoCallback) {
        pages.append("\(start)+\(count)")
        callbacks.append(callback)
    }
}

/// An original the test's host hands out, which says when the guest let
/// go.
final class ScriptedPhotoFile: PhotoFileGrant {

    nonisolated(unsafe) static var released: [Int32] = []

    let directoryValue: Int32
    let nameValue: String
    let type: String

    init(_ directory: Int32, name: String, type: String) {
        self.directoryValue = directory
        self.nameValue = name
        self.type = type
    }

    deinit {
        Self.released.append(directoryValue)
    }

    func directory() -> Int32 { directoryValue }
    func name() -> String { nameValue }
    func contentType() -> String { type }
}

/// A host's photos that only write down what they're asked, and keep the
/// callbacks for the test to answer.
final class ScriptedPhotos: Photos {

    /// The one library, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedPhotos()

    var calls: [String] = []

    var callbacks: [any PhotoCallback] = []

    var delegate: (any PhotosDelegate)?

    var level: Int32 = 0

    static func shared() -> ScriptedPhotos { instance }

    /// The callback of the last operation issued.
    var last: any PhotoCallback { callbacks[callbacks.count - 1] }

    func access() -> Int32 { level }

    func requestAccess(_ callback: any PhotoCallback) {
        calls.append("requestAccess")
        callbacks.append(callback)
    }

    func setDelegate(_ delegate: (any PhotosDelegate)?) {
        calls.append(delegate == nil ? "setDelegate nil" : "setDelegate")
        self.delegate = delegate
    }

    func add(_ directory: Int32, path: String, kind: Int32, callback: any PhotoCallback) {
        calls.append("add \(directory) \(path) \(kind)")
        callbacks.append(callback)
    }

    func fetch(_ kind: Int32, album: String, callback: any PhotoCallback) {
        calls.append("fetch \(kind) [\(album)]")
        callbacks.append(callback)
    }

    func asset(_ identifier: String, callback: any PhotoCallback) {
        calls.append("asset \(identifier)")
        callbacks.append(callback)
    }

    func albums(_ callback: any PhotoCallback) {
        calls.append("albums")
        callbacks.append(callback)
    }

    func file(_ identifier: String, callback: any PhotoCallback) {
        calls.append("file \(identifier)")
        callbacks.append(callback)
    }

    func delete(_ identifiers: [String], callback: any PhotoCallback) {
        calls.append("delete \(identifiers)")
        callbacks.append(callback)
    }
}

/// Records what a view graph sends.
final class PhotoSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func all(_ type: String) -> [RenderNode] {
        (self.type == type ? [self] : []) + children.flatMap { $0.all(type) }
    }
}

struct Roll: View {

    let assets: [PhotoAsset]

    var body: some View {
        VStack {
            ForEach(assets) { asset in
                PhotoView(asset)
            }
            PhotoView(assetID: "kept", scaling: .fit)
        }
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// one library.
@Suite(.serialized) final class DynamicPhotosTests {

    let host = ScriptedPhotos.instance

    let library = PhotoLibrary.shared

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        PhotosProxy.register(ScriptedPhotos.self, in: native)
        PhotoResultsProxy.register(ScriptedPhotoResults.self, in: native)
        PhotoFileGrantProxy.register(ScriptedPhotoFile.self, in: native)
        PhotoCallbackProxy.registerInterface(in: native)
        PhotosDelegateProxy.registerInterface(in: native)
        library.onChange(nil)
        host.calls = []
        host.callbacks = []
        host.level = 0
        ScriptedPhotoResults.released = 0
        ScriptedPhotoFile.released = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, PhotoLibraryError>?) -> PhotoLibraryError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    static let beach = PhotoAsset(id: "A1", kind: .image, creationDate: 1_700_000_000_000, width: 4032, height: 3024, isFavorite: true)

    static let clip = PhotoAsset(id: "B2", kind: .video, creationDate: 1_700_000_100_000, width: 1920, height: 1080, duration: 12.5)

    // MARK: Contracts

    @Test func theLibraryRequiresThePhotoLibrary() {
        let photos = PhotosProxy.descriptor
        #expect(photos.name == "org.pureswift.photos.Photos")
        #expect(photos.capability == .photoLibrary)
        #expect(method(photos, "access")?.signature == Signature("()I"))
        #expect(method(photos, "add:path:kind:callback:")?.signature == Signature("(IOIO)V"))
        #expect(method(photos, "fetch:album:callback:")?.signature == Signature("(IOO)V"))
        #expect(method(photos, "delete:callback:")?.signature == Signature("(OO)V"))
        #expect(photos.methods.count == 10)

        let results = PhotoResultsProxy.descriptor
        #expect(results.name == "org.pureswift.photos.Results" && results.capability == nil)
        #expect(method(results, "count")?.signature == Signature("()I"))
        #expect(method(results, "assets:count:callback:")?.signature == Signature("(IIO)V"))
        #expect(results.methods.count == 2)

        let file = PhotoFileGrantProxy.descriptor
        #expect(file.name == "org.pureswift.photos.File" && file.capability == nil)
        #expect(method(file, "directory")?.signature == Signature("()I"))
        #expect(file.methods.count == 3)

        let callback = PhotoCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.photos.Callback" && callback.kind == .callback)
        #expect(method(callback, "didFetch:")?.signature == Signature("(O)V"))
        #expect(callback.methods.count == 9)
        let delegate = PhotosDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.photos.Delegate" && delegate.kind == .callback)
        #expect(delegate.methods.count == 1)

        let descriptors = [photos, results, file, callback, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Types

    @Test func accessSaysWhatMayBeDone() {
        #expect(PhotoLibraryAccess.authorized.allowsReading && PhotoLibraryAccess.limited.allowsReading)
        #expect(!PhotoLibraryAccess.addOnly.allowsReading && PhotoLibraryAccess.addOnly.allowsAdding)
        #expect(PhotoLibraryAccess.authorized.allowsAdding && PhotoLibraryAccess.limited.allowsAdding)
        for none in [PhotoLibraryAccess.notDetermined, .restricted, .denied, .unavailable] {
            #expect(!none.allowsReading && !none.allowsAdding, "\(none)")
        }
    }

    @Test func anAssetCrossesAsSevenStrings() {
        #expect(Self.beach.fields == ["A1", "1", "1700000000000", "4032", "3024", "0", "1"])
        #expect(Self.clip.fields == ["B2", "2", "1700000100000", "1920", "1080", "12500", "0"])
        #expect(PhotoAsset.assets(PhotoAsset.fields([Self.beach, Self.clip])) == [Self.beach, Self.clip])
        #expect(PhotoAsset.assets([]) == [])
        // A duration that isn't a length of time is none.
        #expect(PhotoAsset(id: "x", duration: .nan).fields[5] == "0")
        #expect(PhotoAsset(id: "x", duration: -3).fields[5] == "0")
        #expect(PhotoAsset(id: "x", duration: .infinity).fields[5] == "0")
        #expect(PhotoAsset(id: "x", duration: 0.0004).fields[5] == "0" && PhotoAsset(id: "x", duration: 0.0006).fields[5] == "1")
    }

    @Test func whatAHostSendsBadlyIsReadSafely() {
        // A remainder is left out, and so is an asset with no identifier.
        let fields = Self.beach.fields + ["", "1", "0", "0", "0", "0", "0"] + Self.clip.fields + ["C3", "1"]
        #expect(PhotoAsset.assets(fields) == [Self.beach, Self.clip])
        // A kind from a newer host is still something to show; numbers
        // that aren't numbers, and sizes below nothing, are none.
        let odd = PhotoAsset.assets(["D4", "9", "soon", "-5", "wide", "-100", "yes"])
        #expect(odd == [PhotoAsset(id: "D4", kind: .image, creationDate: 0, width: 0, height: 0, duration: 0, isFavorite: false)])
    }

    @Test func anAlbumCrossesAsFourStrings() {
        let albums = [
            PhotoAlbum(id: "a", title: "Trip", count: 12, kind: .user),
            PhotoAlbum(id: "b", title: "Videos", count: 3, kind: .smart),
        ]
        #expect(PhotoAlbum.fields(albums) == ["a", "Trip", "12", "1", "b", "Videos", "3", "2"])
        #expect(PhotoAlbum.albums(PhotoAlbum.fields(albums)) == albums)
        // A kind from a newer host isn't one the user made.
        #expect(PhotoAlbum.albums(["c", "Memories", "-1", "7", "d"]) == [PhotoAlbum(id: "c", title: "Memories", count: 0, kind: .smart)])
    }

    // MARK: Access

    @Test func accessIsReadAndNeverAsks() {
        host.level = PhotoLibraryAccess.limited.rawValue
        #expect(library.access == .limited)
        host.level = PhotoLibraryAccess.addOnly.rawValue
        #expect(library.access == .addOnly)
        host.level = 99
        #expect(library.access == .denied, "an access from a newer host isn't one to rely on")
        #expect(host.calls.isEmpty)
    }

    @Test func askingGivesWhatTheUserGranted() {
        var granted: [PhotoLibraryAccess] = []
        library.requestAccess { granted.append($0) }
        #expect(host.calls == ["requestAccess"] && granted.isEmpty)
        host.last.didChangeAccess(PhotoLibraryAccess.authorized.rawValue)
        host.last.didChangeAccess(PhotoLibraryAccess.denied.rawValue)
        #expect(granted == [.authorized], "only a host's first answer counts")

        library.requestAccess { granted.append($0) }
        host.last.didComplete()
        library.requestAccess { granted.append($0) }
        host.last.didChangeAccess(42)
        #expect(granted == [.authorized, .denied, .denied], "an answer of the wrong kind, or an unknown access, is no access")
    }

    // MARK: Adding

    @Test func addingNamesAFileAndItsKind() throws {
        var results: [Result<PhotoAsset?, PhotoLibraryError>] = []
        library.add(photo: .caches / "shot.jpg") { results.append($0) }
        #expect(host.calls == ["add \(FileDirectory.caches.rawValue) shot.jpg 1"])
        host.last.didAdd(Self.beach.fields)
        #expect(try results[0].get() == Self.beach)

        library.add(video: .documents / "clips" / "a.mp4") { results.append($0) }
        #expect(host.calls.last == "add \(FileDirectory.documents.rawValue) clips/a.mp4 2")
        host.last.didAdd([])
        #expect(try results[1].get() == nil, "an app that may only add isn't told which asset it made")

        library.add(photo: .caches / "notes.txt") { results.append($0) }
        host.last.didFail(PhotoLibraryError.invalidData.rawValue)
        #expect(error(results[2]) == .invalidData)
        library.add(photo: .caches / "shot.jpg") { results.append($0) }
        host.last.didComplete()
        #expect(error(results[3]) == .unknown)
    }

    // MARK: Browsing

    @Test func aFetchIsACountAndAWindow() throws {
        var fetched: Result<PhotoFetchResult, PhotoLibraryError>?
        library.assets { fetched = $0 }
        #expect(host.calls == ["fetch 0 []"])
        let results = ScriptedPhotoResults(130)
        host.last.didFetch(results)
        let recent = try #require(fetched).get()
        #expect(recent.count == 130 && !recent.isEmpty)

        var page: Result<[PhotoAsset], PhotoLibraryError>?
        recent.assets(in: 0 ..< 60) { page = $0 }
        #expect(results.pages == ["0+60"])
        results.callbacks[0].didListAssets(PhotoAsset.fields([Self.clip, Self.beach]))
        #expect(try #require(page).get() == [Self.clip, Self.beach])

        // What's past the end isn't asked for.
        recent.assets(in: 120 ..< 180) { page = $0 }
        #expect(results.pages.last == "120+10")
        results.callbacks[1].didFail(PhotoLibraryError.notAuthorized.rawValue)
        #expect(error(page) == .notAuthorized)

        page = nil
        recent.assets(in: 130 ..< 200) { page = $0 }
        recent.assets(in: 40 ..< 40) { _ in }
        #expect(try #require(page).get().isEmpty)
        #expect(results.pages.count == 2, "nothing to read is nothing to ask")
        recent.assets(in: -20 ..< 5) { _ in }
        #expect(results.pages.last == "0+5")

        recent.assets(in: 0 ..< 1) { page = $0 }
        results.callbacks[3].didFindAsset(Self.beach.fields)
        #expect(error(page) == .unknown)
    }

    @Test func aFetchMayBeOfAKindOrAnAlbum() throws {
        let trip = PhotoAlbum(id: "album-7", title: "Trip")
        var fetched: [Result<PhotoFetchResult, PhotoLibraryError>] = []
        library.assets(of: .video) { fetched.append($0) }
        library.assets(in: trip) { fetched.append($0) }
        library.assets(of: .image, in: trip) { fetched.append($0) }
        #expect(host.calls == ["fetch 2 []", "fetch 0 [album-7]", "fetch 1 [album-7]"])
        host.callbacks[0].didFetch(ScriptedPhotoResults(0))
        host.callbacks[1].didFail(PhotoLibraryError.notFound.rawValue)
        host.callbacks[2].didFetch(ScriptedPhotoResults(-4))
        #expect(try fetched[0].get().isEmpty)
        #expect(error(fetched[1]) == .notFound)
        #expect(try fetched[2].get().count == 0, "a count below nothing is nothing")
    }

    @Test func aFetchIsForgottenWhenItsResultIsReleased() throws {
        do {
            var fetched: Result<PhotoFetchResult, PhotoLibraryError>?
            library.assets { fetched = $0 }
            host.last.didFetch(ScriptedPhotoResults(3))
            host.callbacks = []
            #expect(try #require(fetched).get().count == 3)
            #expect(ScriptedPhotoResults.released == 0)
        }
        #expect(ScriptedPhotoResults.released == 1)
    }

    @Test func oneAssetIsFoundOrGone() throws {
        var found: [Result<PhotoAsset?, PhotoLibraryError>] = []
        library.asset(withID: "A1") { found.append($0) }
        #expect(host.calls == ["asset A1"])
        host.last.didFindAsset(Self.beach.fields)
        library.asset(withID: "Z9") { found.append($0) }
        host.last.didFindAsset([])
        #expect(try found[0].get() == Self.beach)
        #expect(try found[1].get() == nil)
    }

    @Test func albumsAreListed() throws {
        var listed: Result<[PhotoAlbum], PhotoLibraryError>?
        library.albums { listed = $0 }
        #expect(host.calls == ["albums"])
        host.last.didListAlbums(["a", "Trip", "12", "1", "b", "Favourites", "40", "2"])
        let albums = try #require(listed).get()
        #expect(albums.map(\.title) == ["Trip", "Favourites"])
        #expect(albums.map(\.kind) == [.user, .smart] && albums.map(\.count) == [12, 40])
    }

    // MARK: Originals

    @Test func anOriginalIsAFileWhileItsHeld() throws {
        do {
            var opened: Result<PhotoFile, PhotoLibraryError>?
            library.file(for: Self.clip) { opened = $0 }
            #expect(host.calls == ["file B2"])
            host.last.didOpenFile(ScriptedPhotoFile(300, name: "IMG_0042.MOV", type: "video/quicktime"))
            host.callbacks = []
            let file = try #require(opened).get()
            #expect(file.path == FilePath(FileDirectory(rawValue: 300)))
            #expect(file.contentType == "video/quicktime" && file.name == "IMG_0042.MOV")
            #expect(ScriptedPhotoFile.released.isEmpty)
        }
        #expect(ScriptedPhotoFile.released == [300], "releasing it ends the access")

        var opened: Result<PhotoFile, PhotoLibraryError>?
        library.file(for: Self.beach) { opened = $0 }
        host.last.didOpenFile(ScriptedPhotoFile(301, name: "", type: "image/heic"))
        #expect(try #require(opened).get().name == nil)
        library.file(for: Self.beach) { opened = $0 }
        host.last.didFail(PhotoLibraryError.unavailable.rawValue)
        #expect(error(opened) == .unavailable, "offline, with the original in the cloud")
    }

    // MARK: Deleting

    @Test func deletingIsTheUsersToConfirm() {
        var results: [Result<Void, PhotoLibraryError>] = []
        library.delete([Self.beach, Self.clip]) { results.append($0) }
        #expect(host.calls == [#"delete ["A1", "B2"]"#])
        host.last.didComplete()
        library.delete([Self.beach]) { results.append($0) }
        host.last.didFail(PhotoLibraryError.cancelledByUser.rawValue)
        #expect(error(results[0]) == nil)
        #expect(error(results[1]) == .cancelledByUser)
    }

    // MARK: Changes

    @Test func changesAreHeardByOneListener() {
        var first = 0
        var second = 0
        library.onChange { first += 1 }
        #expect(host.calls == ["setDelegate"])
        host.delegate?.didChange()
        library.onChange { second += 1 }
        host.delegate?.didChange()
        host.delegate?.didChange()
        #expect(first == 1 && second == 2)
        library.onChange(nil)
        #expect(host.calls.last == "setDelegate nil" && host.delegate == nil)
    }

    @Test func aStreamOfChangesEndsItsListening() async {
        var seen = 0
        do {
            let changes = library.changes
            #expect(host.calls == ["setDelegate"])
            host.delegate?.didChange()
            host.delegate?.didChange()
            for await _ in changes {
                seen += 1
                if seen == 2 { break }
            }
        }
        #expect(seen == 2)
        #expect(host.calls.last == "setDelegate nil", "ending the loop stops listening")
    }

    // MARK: Views

    @Test func aPhotoNodeNamesItsAsset() throws {
        let sink = PhotoSink()
        let graph = ViewGraph(Roll(assets: [Self.beach, Self.clip]), sink: sink)
        graph.update()
        let nodes = try #require(sink.screen).all("Photo")
        #expect(nodes.map { $0.props["asset"] } == ["A1", "B2", "kept"])
        #expect(nodes.map { $0.props["scaling"] } == ["fill", "fill", "fit"])
        #expect(nodes.allSatisfy { $0.props.count == 2 && $0.children.isEmpty })
        #expect(host.calls.isEmpty, "showing a photo asks the library nothing")
    }
}
