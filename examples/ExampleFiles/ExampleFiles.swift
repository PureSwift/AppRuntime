import DynamicRuntime
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The example files app: a notebook kept as text files. It reads a welcome
/// text from the bundle, saves each note as `notes/<title>.txt` in the
/// documents directory, lists, opens and deletes them, and exports them all
/// into one file in the caches directory.

struct Note: Identifiable {
    /// The note's title: its file's name without `.txt`.
    let id: String
}

/// The guest is single-threaded (§6.4), which the compiler can't see: the
/// export's task captures the notebook.
@Observable
final class Notebook: @unchecked Sendable {

    var notes: [Note] = []

    var title: String = ""

    var text: String = ""

    /// The contents of the note that was opened.
    var opened: String = ""

    /// From the bundle.
    var welcome: String = ""

    var status: String = ""

    @ObservationIgnored let files = FileManager.default

    static let folder: FilePath = .documents / "notes"

    static func path(_ title: String) -> FilePath {
        folder / (title + ".txt")
    }

    /// The closures hold the notebook, which lives as long as the app does:
    /// Embedded Swift has no weak or unowned references.
    func start() {
        files.contents(at: .bundle / "welcome.txt") { result in
            switch result {
            case .success(let bytes):
                self.welcome = String(decoding: bytes, as: UTF8.self)
            case .failure(.notFound):
                self.welcome = "No welcome.txt in the bundle."
            case .failure(let error):
                self.report("welcome", error)
            }
        }
        refresh()
    }

    func refresh() {
        files.contentsOfDirectory(at: Self.folder) { result in
            switch result {
            case .success(let names):
                // Files only; a directory's name ends in "/".
                self.notes = names.filter { $0.hasSuffix(".txt") }.map { Note(id: String($0.dropLast(4))) }
            case .failure(.notFound):
                // Nothing saved yet: writing the first note makes the folder.
                self.notes = []
            case .failure(let error):
                self.report("list", error)
            }
        }
    }

    func save() {
        let title = self.title
        guard !title.isEmpty else {
            status = "A note needs a title."
            return
        }
        files.write(Array(text.utf8), to: Self.path(title)) { result in
            switch result {
            case .success:
                self.status = "Saved \(title)"
                self.title = ""
                self.text = ""
                self.refresh()
            case .failure(let error):
                self.report("save", error)
            }
        }
    }

    func open(_ note: Note) {
        files.contents(at: Self.path(note.id)) { result in
            switch result {
            case .success(let bytes):
                self.opened = String(decoding: bytes, as: UTF8.self)
            case .failure(let error):
                self.report("open", error)
            }
        }
    }

    func delete(_ note: Note) {
        files.removeItem(at: Self.path(note.id)) { result in
            switch result {
            case .success:
                self.status = "Deleted \(note.id)"
                self.opened = ""
                self.refresh()
            case .failure(let error):
                self.report("delete", error)
            }
        }
    }

    func report(_ what: String, _ error: FileError) {
        status = "Couldn't \(what): error \(error.rawValue)"
    }

    #if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
    /// Every note into one file, with `async`/`await`. Embedded builds
    /// only: in host builds Swift's own executor would run it on another
    /// thread.
    func export() {
        Task {
            do throws(FileError) {
                var all: [UInt8] = []
                for note in self.notes {
                    all += Array("# \(note.id)\n".utf8)
                    all += try await self.files.contents(at: Self.path(note.id))
                    all += Array("\n".utf8)
                }
                try await self.files.write(all, to: .caches / "exports/all.txt")
                let size = try await self.files.attributesOfItem(at: .caches / "exports/all.txt").size
                self.status = "Exported \(self.notes.count) notes, \(size) bytes"
            } catch {
                self.report("export", error)
            }
        }
    }
    #else
    func export() {
        status = "Export needs the concurrency runtime."
    }
    #endif
}

struct ContentView: View {

    @Bindable var notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notebook.welcome)
                .accessibilityIdentifier("welcome")
            TextField("Title", text: $notebook.title)
                .accessibilityIdentifier("title")
            TextField("Text", text: $notebook.text)
                .accessibilityIdentifier("text")
            HStack(spacing: 8) {
                Button("Save") { notebook.save() }
                Button("Export") { notebook.export() }
            }
            ForEach(notebook.notes) { note in
                HStack(spacing: 8) {
                    Button(note.id) { notebook.open(note) }
                    Button("Delete \(note.id)") { notebook.delete(note) }
                }
            }
            Text(notebook.opened)
                .accessibilityIdentifier("opened")
            Text(notebook.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleFilesApp: App {

    let notebook = Notebook()

    init() {
        notebook.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(notebook: notebook)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleFilesMain() -> rt_status {
    Runtime.main { ExampleFilesApp.run() }
}
