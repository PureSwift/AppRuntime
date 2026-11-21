import DynamicRuntime
import DynamicClipboard
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example clipboard app: a sum to copy, and a place to paste. It
/// copies text, a link and its logo, copies a code as sensitive, says what
/// there is to paste without reading it, and pastes text, a link and an
/// image, the image into a file.

/// The closures hold the desk, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Desk: @unchecked Sendable {

    /// What the app has to copy.
    var result: String = "6 × 7 = 42"

    /// What was last pasted.
    var pasted: String = ""

    var status: String = ""

    /// How often the app was asked to look at the clipboard again. An
    /// app would look when it comes to the front.
    var looks: Int = 0

    @ObservationIgnored let pasteboard = Pasteboard.general

    static let link = "https://swift.org"

    static let picture: FilePath = .caches / "pasted"

    func copyResult() {
        pasteboard.setString(result) { self.copied("Copied the sum", $0) }
    }

    func copyLink() {
        pasteboard.setURL(Self.link, title: "Swift") { self.copied("Copied the link", $0) }
    }

    /// A code: kept out of previews and history where the platform can.
    func copyCode() {
        pasteboard.setString("493 201", options: .sensitive) { self.copied("Copied the code", $0) }
    }

    /// From the bundle: the image's bytes don't pass through the app.
    func copyLogo() {
        pasteboard.setImage(contentsOf: .bundle / "logo.png") { self.copied("Copied the logo", $0) }
    }

    func clear() {
        pasteboard.clear { self.copied("Cleared", $0) }
    }

    func pasteText() {
        pasteboard.string { result in
            switch result {
            case .success(let text?):
                self.pasted = text
                self.status = "Pasted text"
            case .success(nil):
                self.status = "No text to paste"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func pasteLink() {
        pasteboard.url { result in
            switch result {
            case .success(let link?):
                self.pasted = link
                self.status = "Pasted a link"
            case .success(nil):
                self.status = "No link to paste"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    /// Into a file: the image's bytes don't pass through the app.
    func pasteImage() {
        pasteboard.image(to: Self.picture) { result in
            switch result {
            case .success(let type?):
                self.pasted = "caches/pasted"
                self.status = "Pasted an image: \(type.mimeType)"
            case .success(nil):
                self.status = "No image to paste"
            case .failure(let error):
                self.report(error)
            }
        }
    }

    func copied(_ what: String, _ result: Result<Void, PasteboardError>) {
        switch result {
        case .success: status = what
        case .failure(let error): report(error)
        }
    }

    func report(_ error: PasteboardError) {
        switch error {
        case .notAllowed: status = "Not allowed"
        case .invalidData: status = "Not an image"
        case .tooLarge: status = "Too large"
        case .unsupported: status = "Not supported here"
        default: status = "Failed: error \(error.rawValue)"
        }
    }

    /// What there is to paste, without reading it. The clipboard isn't
    /// observable: the view looks again when `status` or `looks` changes.
    var offer: String {
        _ = looks
        var kinds: [String] = []
        if pasteboard.hasURLs { kinds.append("a link") }
        if pasteboard.hasStrings { kinds.append("text") }
        if pasteboard.hasImages { kinds.append("an image") }
        return kinds.isEmpty ? "Nothing to paste" : "To paste: " + kinds.joined(separator: ", ")
    }
}

struct ContentView: View {

    let desk: Desk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The user can select this and copy it with no code of the app's.
            Text(desk.result)
                .textSelection(.enabled)
                .accessibilityIdentifier("result")
            HStack(spacing: 8) {
                Button("Copy") { desk.copyResult() }
                Button("Copy Link") { desk.copyLink() }
                Button("Copy Code") { desk.copyCode() }
                Button("Copy Logo") { desk.copyLogo() }
                Button("Clear") { desk.clear() }
                Button("Look") { desk.looks += 1 }
            }
            Text(desk.offer)
                .accessibilityIdentifier("offer")
            HStack(spacing: 8) {
                Button("Paste") { desk.pasteText() }
                    .disabled(!desk.pasteboard.hasStrings)
                Button("Paste Link") { desk.pasteLink() }
                    .disabled(!desk.pasteboard.hasURLs)
                Button("Paste Image") { desk.pasteImage() }
                    .disabled(!desk.pasteboard.hasImages)
            }
            Text(desk.pasted)
                .accessibilityIdentifier("pasted")
            Text(desk.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleClipboardApp: App {

    let desk = Desk()

    var body: some Scene {
        WindowGroup {
            ContentView(desk: desk)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleClipboardMain() -> rt_status {
    Runtime.main { ExampleClipboardApp.run() }
}
