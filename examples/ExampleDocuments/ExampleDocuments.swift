import DynamicRuntime
import DynamicDocuments
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example documents app: a small text editor for the user's own files.
/// It opens a text file the user picks, or one the app is opened with;
/// saves changes back to that file; saves a copy where the user says, and
/// goes on editing the copy; lists a folder the user picks; and takes a
/// photo the user picks from their photo library, with the system's photo
/// picker.

struct Entry: Identifiable {
    /// A name in the folder; a folder's ends in `/`.
    let id: String
}

/// The closures hold the desk, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Desk: @unchecked Sendable {

    /// The open document's name, as its provider gives it.
    var name: String = "Untitled"

    var text: String = ""

    /// The names in the folder that was picked.
    var entries: [Entry] = []

    var status: String = ""

    /// Whether the importer is showing.
    var importing: Bool = false

    /// The open document. Holding it is what keeps the file reachable.
    @ObservationIgnored var document: Document?

    @ObservationIgnored var folder: Document?

    @ObservationIgnored let picker = DocumentPicker()

    @ObservationIgnored let files = FileManager.default

    static let draft: FilePath = .temporary / "Untitled.txt"

    /// Files the app is opened with arrive here: those it was launched
    /// with, and those that come while it runs.
    func start() {
        DocumentPicker.onOpen { documents in
            if let first = documents.first {
                self.show(first)
            }
        }
    }

    /// What the importer gave.
    func imported(_ result: Result<[Document], DocumentError>) {
        switch result {
        case .success(let documents):
            if let first = documents.first {
                show(first)
            }
        case .failure(let error):
            status = "Couldn't open: error \(error.rawValue)"
        }
    }

    func show(_ document: Document) {
        files.contents(at: document.path) { result in
            switch result {
            case .success(let bytes):
                // Letting go of the one before ends the app's access to it.
                self.document = document
                self.name = document.name
                self.text = String(decoding: bytes, as: UTF8.self)
                self.status = document.isWritable ? "Opened \(document.name)" : "Opened \(document.name), read-only"
            case .failure(let error):
                self.report("read", error)
            }
        }
    }

    /// Writes the text back to the file the user picked.
    func save() {
        guard let document else {
            saveCopy()
            return
        }
        files.write(Array(text.utf8), to: document.path) { result in
            switch result {
            case .success:
                self.status = "Saved \(document.name)"
            case .failure(let error):
                self.report("save", error)
            }
        }
    }

    /// Writes the text to a file of the app's own, then asks the user where
    /// it goes. From then on the copy is the open document.
    func saveCopy() {
        let suggested = document == nil ? "Untitled.txt" : "Copy of " + name
        files.write(Array(text.utf8), to: Self.draft) { result in
            if case .failure(let error) = result {
                self.report("save", error)
                return
            }
            self.picker.export(Self.draft, suggestedName: suggested) { result in
                switch result {
                case .success(.saved(let copy)):
                    self.document = copy
                    self.name = copy.name
                    self.status = "Saved as \(copy.name)"
                case .success(.savedCopy):
                    self.status = "Saved a copy"
                case .success(.cancelled):
                    self.status = "Not saved"
                case .failure(let error):
                    self.status = "Couldn't save a copy: error \(error.rawValue)"
                }
            }
        }
    }

    func openFolder() {
        picker.openFolder { result in
            switch result {
            case .success(let folder?):
                self.folder = folder
                self.files.contentsOfDirectory(at: folder.path) { result in
                    switch result {
                    case .success(let names):
                        self.entries = names.map { Entry(id: $0) }
                        self.status = "\(names.count) in \(folder.name)"
                    case .failure(let error):
                        self.report("list", error)
                    }
                }
            case .success(nil):
                self.status = "No folder picked"
            case .failure(let error):
                self.status = "Couldn't open a folder: error \(error.rawValue)"
            }
        }
    }

    /// Opens a text file from the folder that was picked: a path under the
    /// folder's own.
    func open(entry name: String) {
        guard let folder else { return }
        files.contents(at: folder.path / name) { result in
            switch result {
            case .success(let bytes):
                self.document = nil
                self.name = name
                self.text = String(decoding: bytes, as: UTF8.self)
                self.status = "Read \(name) from \(folder.name)"
            case .failure(let error):
                self.report("read", error)
            }
        }
    }

    /// Asks for a photo from the user's library. The system shows its own
    /// photos screen: the user is asked for no leave, and the app sees
    /// nothing but what's picked, which it reads as any file.
    func attachPhoto() {
        picker.open([.image], from: .photoLibrary) { result in
            switch result {
            case .success(let photo?):
                self.files.contents(at: photo.path) { read in
                    switch read {
                    case .success(let bytes):
                        self.status = "Attached \(photo.name), \(bytes.count) bytes"
                    case .failure(let error):
                        self.report("read", error)
                    }
                }
            case .success(nil):
                self.status = "No photo picked"
            case .failure(let error):
                self.status = "Couldn't pick a photo: error \(error.rawValue)"
            }
        }
    }

    func report(_ what: String, _ error: FileError) {
        status = "Couldn't \(what): error \(error.rawValue)"
    }
}

struct ContentView: View {

    @Bindable var desk: Desk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(desk.name)
                .accessibilityIdentifier("name")
            TextField("Text", text: $desk.text)
                .accessibilityIdentifier("text")
            HStack(spacing: 8) {
                Button("Open") { desk.importing = true }
                Button("Save") { desk.save() }
                Button("Save a Copy") { desk.saveCopy() }
                Button("Open Folder") { desk.openFolder() }
                Button("Attach Photo") { desk.attachPhoto() }
            }
            ForEach(desk.entries) { entry in
                Button(entry.id) { desk.open(entry: entry.id) }
            }
            Text(desk.status)
                .accessibilityIdentifier("status")
        }
        .padding()
        .fileImporter(isPresented: $desk.importing, allowedContentTypes: [.plainText], access: .readWrite) { result in
            desk.imported(result)
        }
    }
}

struct ExampleDocumentsApp: App {

    let desk = Desk()

    init() {
        desk.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(desk: desk)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleDocumentsMain() -> rt_status {
    Runtime.main { ExampleDocumentsApp.run() }
}
