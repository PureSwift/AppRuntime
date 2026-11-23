import DynamicRuntime
import DynamicDocuments
import DynamicDrawing
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example images app: a picture fitted in a scroll view that zooms,
/// with its size and the scale beneath, a thumbnail of it, and a swatch the
/// app makes from pixels. It starts with a PNG it writes to its own
/// caches, and opens an image the user picks instead. No pixel of either
/// file passes through the app: the host reads and decodes them.

/// The closures hold the gallery, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Gallery: @unchecked Sendable {

    /// What's shown, and a small copy of it.
    var picture: Image?

    var thumbnail: Image?

    var name: String = ""

    var size: String = ""

    var zoom: Double = 1.0

    var status: String = ""

    /// Two points square, from pixels at a scale of 2.
    var swatch: Image?

    /// The picked image's document. Holding it is what keeps the file
    /// readable.
    @ObservationIgnored var document: Document?

    @ObservationIgnored let picker = DocumentPicker()

    static let sample: FilePath = .caches / "sample.png"

    func start() {
        let blue: [UInt8] = [40, 120, 200, 255]
        let orange: [UInt8] = [240, 140, 30, 255]
        swatch = Image(pixels: blue + orange + orange + blue, width: 2, height: 2, scale: 2)
        FileManager.default.write(samplePNG, to: Self.sample) { result in
            switch result {
            case .success:
                self.show(Self.sample, named: "sample.png")
            case .failure(let error):
                self.status = "Couldn't write the sample: error \(error.rawValue)"
            }
        }
    }

    /// Shows a file: the header is read for its size, and the host decodes
    /// it for the size it's drawn at.
    func show(_ file: FilePath, named name: String) {
        let picture = Image(contentsOf: file)
        self.picture = picture
        thumbnail = Image(contentsOf: file, maximumPixelSize: 64)
        self.name = name
        zoom = 1
        size = "Reading…"
        picture.size { result in
            switch result {
            case .success(let size):
                self.size = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
            case .failure(let error):
                self.size = "Can't be read: error \(error.rawValue)"
            }
        }
    }

    /// Asks for an image file. Letting go of the document before ends the
    /// app's access to it.
    func pick() {
        picker.open([.image]) { result in
            switch result {
            case .success(let document?):
                self.document = document
                self.show(document.path, named: document.name)
                self.status = "Opened \(document.name)"
            case .success(nil):
                self.status = "No image picked"
            case .failure(let error):
                self.status = "Couldn't pick an image: error \(error.rawValue)"
            }
        }
    }
}

struct ContentView: View {

    @Bindable var gallery: Gallery

    var body: some View {
        VStack(spacing: 8) {
            Text(gallery.name)
                .accessibilityIdentifier("name")
            if let picture = gallery.picture {
                ScrollView([.horizontal, .vertical]) {
                    picture
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(gallery.name)
                }
                .zoomable(1...8, scale: $gallery.zoom)
                .frame(height: 240)
            }
            Text(gallery.size)
                .accessibilityIdentifier("size")
            Text("Zoom \(Int((gallery.zoom * 100).rounded()))%")
                .accessibilityIdentifier("zoom")
            HStack(spacing: 8) {
                if let thumbnail = gallery.thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipped()
                }
                if let swatch = gallery.swatch {
                    swatch
                }
            }
            HStack(spacing: 8) {
                Button("Open an Image") { gallery.pick() }
                Button("Fit") { gallery.zoom = 1 }
            }
            Text(gallery.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleImagesApp: App {

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
public func exampleImagesMain() -> rt_status {
    Runtime.main { ExampleImagesApp.run() }
}

/// A 40 by 30 PNG of one blue.
let samplePNG: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x1E,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x5E, 0xDD, 0x5C, 0xDD, 0x00, 0x00, 0x00,
    0x32, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0xED, 0xCE, 0x31, 0x01, 0x00,
    0x00, 0x04, 0x00, 0x30, 0x71, 0x44, 0x14, 0x51, 0x2B, 0x12, 0xF8, 0x1D,
    0x3B, 0xF6, 0x2F, 0xB2, 0x7A, 0x3E, 0x0B, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0xC1, 0xCB, 0x02, 0xF1, 0x3C, 0x43, 0x76, 0xA0, 0x52, 0xAC, 0x86, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]
