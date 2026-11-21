import DynamicRuntime
import DynamicFiles
import DynamicPhotos
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example photos app: a gallery. It asks for the user's photos, shows
/// the newest in a grid a page at a time, lists the albums and shows one,
/// shows a photo large, opens its original as a file, deletes it with the
/// user's leave, and looks again whenever the library says it changed.

/// The closures hold the gallery, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Gallery: @unchecked Sendable {

    var status: String = "Not asked"

    /// The pages read so far, newest first.
    var assets: [PhotoAsset] = []

    var albums: [PhotoAlbum] = []

    /// The photo shown large.
    var selected: PhotoAsset?

    var detail: String = ""

    /// The album shown; `nil` is the whole library.
    @ObservationIgnored var album: PhotoAlbum?

    /// The fetch the grid reads its pages from.
    @ObservationIgnored var results: PhotoFetchResult?

    /// The original that's open. Holding it is what keeps the file
    /// reachable.
    @ObservationIgnored var original: PhotoFile?

    @ObservationIgnored let library = PhotoLibrary.shared

    @ObservationIgnored let files = FileManager.default

    /// A grid's screenful. A real one is a few dozen.
    static let pageSize = 4

    func start() {
        // The library says when anything changes, this app's own
        // deletions included: one place to look again.
        library.onChange {
            self.reload()
        }
        show(library.access)
    }

    func allow() {
        library.requestAccess { access in
            self.show(access)
        }
    }

    func show(_ access: PhotoLibraryAccess) {
        switch access {
        case .authorized, .limited:
            reload()
        case .notDetermined, .addOnly:
            status = "Not asked"
        case .unavailable:
            status = "No photo library here"
        default:
            status = "Not allowed"
        }
    }

    func show(album: PhotoAlbum?) {
        self.album = album
        reload()
    }

    /// Fetches again, and reads the first page. A fetch is the library as
    /// it was when it was made.
    func reload() {
        library.albums { result in
            if case .success(let albums) = result {
                self.albums = albums
            }
        }
        let wanted = album
        library.assets(in: wanted) { result in
            // Another album was asked for meanwhile.
            guard wanted?.id == self.album?.id else { return }
            switch result {
            case .success(let results):
                self.results = results
                self.assets = []
                self.more()
            case .failure(.notFound) where wanted != nil:
                // The album went: back to everything.
                self.show(album: nil)
            case .failure(let error):
                self.report(error)
            }
        }
    }

    /// Reads the next page of the fetch.
    func more() {
        guard let results else { return }
        let start = assets.count
        results.assets(in: start ..< start + Self.pageSize) { page in
            // A newer fetch replaced this one.
            guard results === self.results else { return }
            switch page {
            case .success(let assets):
                self.assets += assets
                let place = self.album.map { " in " + $0.title } ?? ""
                self.status = results.isEmpty ? "No photos" + place : "\(self.assets.count) of \(results.count)" + place
                if let selected = self.selected, start == 0, !assets.contains(where: { $0.id == selected.id }) {
                    self.close()
                }
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func select(_ asset: PhotoAsset) {
        original = nil
        selected = asset
        detail = Self.describe(asset)
    }

    func close() {
        original = nil
        selected = nil
        detail = ""
    }

    /// Asks for the selected photo's original, and reads it as any file.
    func openOriginal() {
        guard let selected else { return }
        library.file(for: selected) { result in
            switch result {
            case .success(let file):
                self.files.contents(at: file.path) { read in
                    guard self.selected?.id == selected.id else { return }
                    switch read {
                    case .success(let bytes):
                        // Kept while it's shown.
                        self.original = file
                        self.detail = (file.name ?? "Unnamed") + ", " + file.contentType + ", \(bytes.count) bytes"
                    case .failure(let error):
                        self.status = "Couldn't read the original: error \(error.rawValue)"
                    }
                }
            case .failure(.unavailable):
                self.status = "The original isn't on this device"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    /// The system asks the user before anything goes.
    func delete() {
        guard let selected else { return }
        library.delete([selected]) { result in
            switch result {
            case .success:
                self.close()
            case .failure(.cancelledByUser):
                self.status = "Kept"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func report(_ error: PhotoLibraryError) {
        switch error {
        case .notAuthorized: status = "Not allowed"
        case .unavailable: status = "No photo library here"
        case .notFound: status = "It's gone"
        default: status = "Photos error \(error.rawValue)"
        }
    }

    /// "Video 1920x1080, 12s, favourite".
    static func describe(_ asset: PhotoAsset) -> String {
        var text = (asset.kind == .video ? "Video" : "Photo") + " \(asset.width)x\(asset.height)"
        if asset.kind == .video {
            text += ", \(Int(asset.duration))s"
        }
        if asset.isFavorite {
            text += ", favourite"
        }
        return text
    }
}

struct ContentView: View {

    let gallery: Gallery

    let columns = [GridItem(.adaptive(minimum: 100))]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(gallery.status)
                .accessibilityIdentifier("status")
            HStack(spacing: 8) {
                Button("Allow") { gallery.allow() }
                Button("All") { gallery.show(album: nil) }
                ForEach(gallery.albums) { album in
                    Button(album.title + " (\(album.count))") { gallery.show(album: album) }
                }
            }
            LazyVGrid(columns: columns) {
                ForEach(gallery.assets) { asset in
                    // The host draws it: no pixel comes here.
                    PhotoView(asset)
                        .frame(height: 110)
                        .onTapGesture { gallery.select(asset) }
                }
            }
            Button("More") { gallery.more() }
            if let selected = gallery.selected {
                PhotoView(selected, scaling: .fit)
                    .frame(height: 300)
                    .accessibilityIdentifier("large")
                Text(gallery.detail)
                    .accessibilityIdentifier("detail")
                HStack(spacing: 8) {
                    Button("Original") { gallery.openOriginal() }
                    Button("Delete") { gallery.delete() }
                    Button("Close") { gallery.close() }
                }
            }
        }
        .padding()
    }
}

struct ExamplePhotosApp: App {

    let gallery = Gallery()

    init() {
        gallery.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(gallery: gallery)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func examplePhotosMain() -> rt_status {
    Runtime.main { ExamplePhotosApp.run() }
}
