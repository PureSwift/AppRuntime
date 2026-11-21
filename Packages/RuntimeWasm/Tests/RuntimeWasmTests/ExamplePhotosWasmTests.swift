import Foundation
import Testing
import DynamicFiles
import DynamicPhotos
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimePhotos
import RuntimeWasm

/// The example photos app as App.wasm under WasmKit, with the shared host
/// implementation over a photo library in memory and real files in a
/// temporary directory: the guest's `PhotoLibrary`, `PhotoFetchResult`,
/// `PhotoView` and `FileManager`, the `Photos` contract with its results
/// and files, and `HostPhotos` granting an original in `HostFiles`, end to
/// end. Part of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExamplePhotos`; skipped without it.
    static var examplePhotosURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExamplePhotos/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.examplePhotosURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExamplePhotos"))
    func examplePhotosInWasmMode() throws {
        let native = NativeRuntime.shared
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExamplePhotos-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        // The hosts do their work at once, so each tap's answer is there
        // when the tap returns.
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Container/Documents").path,
            .caches: root.appendingPathComponent("Container/Caches").path,
            .temporary: root.appendingPathComponent("Container/tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        // The user's photos, as the camera and a sync left them: the
        // oldest first made.
        let store = MemoryPhotoStore(directory: root.appendingPathComponent("Originals").path)
        let trip = store.makeAlbum("Trip")
        let picture: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 60)
        let film: [UInt8] = [0, 0, 0, 20] + Array("ftypqt  ".utf8) + [UInt8](repeating: 9, count: 100)
        let assets = [
            store.insert(picture, name: "IMG_0001.JPG", creationDate: 1000, width: 4032, height: 3024, albums: [trip.id]),
            store.insert(picture, name: "IMG_0002.JPG", creationDate: 2000, width: 3024, height: 4032, isFavorite: true),
            store.insert(film, kind: .video, contentType: "video/quicktime", name: "IMG_0003.MOV", creationDate: 3000,
                         width: 1920, height: 1080, duration: 12.5, albums: [trip.id], isInCloud: true),
            store.insert(picture, name: "IMG_0004.JPG", creationDate: 4000, width: 4032, height: 3024, albums: [trip.id]),
            store.insert(picture, name: "IMG_0005.JPG", creationDate: 5000, width: 4032, height: 3024),
            store.insert(picture, name: "IMG_0006.JPG", creationDate: 6000, width: 4032, height: 3024),
        ]
        var questions = 0
        var confirmsDeletion = false
        var deletions: [[String]] = []
        HostPhotos.reset()
        HostPhotos.store = store
        HostPhotos.requester = { completion in
            questions += 1
            completion(.authorized)
        }
        // The system's own question, which the user answers.
        HostPhotos.deleter = { identifiers, completion in
            deletions.append(identifiers)
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
        HostPhotos.work = { $0() }
        HostPhotos.deliver = { $0() }
        HostPhotosModule.register(in: native)
        defer { HostPhotos.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.examplePhotosURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.photoLibrary])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.photos.Photos" }?.capability == .photoLibrary)
        #expect(contracts.contains { $0.name == "org.pureswift.photos.Results" } && contracts.contains { $0.name == "org.pureswift.photos.File" })
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        /// The grid's cells, asked for as a host asks for those it shows.
        func cells() throws -> [RenderNode] {
            let grid = try #require(renderer.screen?.first { $0.type == "LazyVGrid" })
            let id = RenderCodec.encode(id: grid.id)
            return try (0 ..< renderer.delegate.rowCount(id)).map { try RenderCodec.decode(renderer.delegate.row(id, index: $0)) }
        }
        func shown() throws -> [PropValue?] {
            try cells().map { $0.props["asset"] }
        }
        func ids(_ indices: [Int]) -> [PropValue?] {
            indices.map { .string(assets[$0].id) }
        }

        // Nothing is read before the user is asked.
        #expect(text("status") == "Not asked" && questions == 0)
        #expect(try cells().isEmpty)
        #expect(renderer.screen?.button("Trip (3)") == nil)

        // A page of the newest, drawn by the host: each cell names its asset.
        try tap("Allow")
        #expect(questions == 1 && text("status") == "4 of 6")
        #expect(try shown() == ids([5, 4, 3, 2]), "newest first")
        let cell = try #require(try cells().first)
        #expect(cell.type == "Photo" && cell.props["scaling"] == "fill" && cell.children.isEmpty)
        #expect(cell.modifiers.contains { $0.kind == "frame" } && cell.modifiers.contains { $0.kind == "onTapGesture" })
        #expect(renderer.screen?.button("Trip (3)") != nil && renderer.screen?.button("Favourites (1)") != nil)
        #expect(renderer.screen?.button("Videos (1)") != nil)

        try tap("More")
        #expect(text("status") == "6 of 6")
        #expect(try shown() == ids([5, 4, 3, 2, 1, 0]))
        try tap("More")
        #expect(text("status") == "6 of 6")
        #expect(try cells().count == 6, "nothing past the end")

        try tap("Trip (3)")
        #expect(text("status") == "3 of 3 in Trip")
        #expect(try shown() == ids([3, 2, 0]))
        try tap("Videos (1)")
        #expect(text("status") == "1 of 1 in Videos")
        #expect(try shown() == ids([2]))

        // A photo shown large is the same asset, at another size.
        #expect(renderer.screen?.identified("large") == nil)
        renderer.send(try #require(try cells().first), .tap)
        let large = try #require(renderer.screen?.identified("large"))
        #expect(large.type == "Photo" && large.props["asset"] == .string(assets[2].id) && large.props["scaling"] == "fit")
        #expect(text("detail") == "Video 1920x1080, 12s")

        // Its original is a file, fetched from the cloud, and read as any file.
        try tap("Original")
        #expect(text("detail") == .string("IMG_0003.MOV, video/quicktime, \(film.count) bytes"))
        #expect(store.heldOriginals.count == 1, "held while it's shown")
        try tap("Close")
        #expect(store.heldOriginals.isEmpty, "the host removes its copy when the guest lets go")
        #expect(renderer.screen?.identified("large") == nil)
        renderer.send(try #require(try cells().first), .tap)
        store.isOnline = false
        try tap("Original")
        #expect(text("status") == "The original isn't on this device")
        store.isOnline = true

        // Deleting is the user's to confirm.
        try tap("Delete")
        #expect(deletions == [[assets[2].id]] && text("status") == "Kept" && store.allAssets.count == 6)
        confirmsDeletion = true
        try tap("Delete")
        #expect(store.allAssets.count == 5 && renderer.screen?.identified("large") == nil)
        #expect(text("status") == "No photos in Videos", "the library said it changed, and the app looked again")
        #expect(renderer.screen?.button("Videos (0)") != nil && renderer.screen?.button("Trip (2)") != nil)

        // Another app adds one, and the library says so.
        try tap("All")
        #expect(text("status") == "4 of 5")
        let newer = store.insert(picture, name: "IMG_0007.JPG", creationDate: 7000, width: 4032, height: 3024, isFavorite: true)
        #expect(try shown().first == .string(assets[5].id), "not seen until the library says")
        HostPhotos.libraryChanged()
        #expect(text("status") == "4 of 6")
        #expect(try shown().first == .string(newer.id))
        #expect(renderer.screen?.button("Favourites (2)") != nil)
        renderer.send(try #require(try cells().first), .tap)
        #expect(text("detail") == "Photo 4032x3024, favourite")

        // The user gives the app a few photos, and not the rest.
        HostPhotos.access = .limited
        store.chosen = [assets[0].id, assets[1].id]
        try tap("All")
        #expect(text("status") == "2 of 2")
        #expect(try shown() == ids([1, 0]))
        #expect(renderer.screen?.identified("large") == nil, "the one shown large isn't among them")

        // And then takes the access back in the system's settings.
        HostPhotos.access = .denied
        try tap("All")
        #expect(text("status") == "Not allowed")
        #expect(questions == 1, "asked once")
    }
}
