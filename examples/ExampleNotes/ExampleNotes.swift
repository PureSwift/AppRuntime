import DynamicRuntime
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example notes app: folders, their notes and a note, in a split view
/// the host collapses into a stack at compact width. It reads the window's
/// size class and color scheme in the note, the text size in each row, and
/// dismisses the sheet that adds a note.

struct Folder: Identifiable {
    let id: Int
    let name: String
}

struct Note: Identifiable {
    let id: Int
    let folder: Int
    var title: String
    var text: String
}

/// The guest is single-threaded (§6.4), which the compiler can't see.
@Observable
final class Notebook: @unchecked Sendable {

    var folders: [Folder] = [
        Folder(id: 1, name: "Work"),
        Folder(id: 2, name: "Home"),
    ]

    var notes: [Note] = [
        Note(id: 1, folder: 1, title: "Plan", text: "Ship the split view."),
        Note(id: 2, folder: 1, title: "Standup", text: "Environment values are in."),
        Note(id: 3, folder: 2, title: "Groceries", text: "Bread, milk."),
    ]

    var nextID: Int = 4

    func notes(in folder: Int) -> [Note] {
        notes.filter { $0.folder == folder }
    }

    func note(_ id: Int) -> Note? {
        notes.first { $0.id == id }
    }

    func name(of folder: Int) -> String {
        folders.first { $0.id == folder }?.name ?? ""
    }

    /// Adds a note to `folder`; returns its ID.
    func add(_ title: String, to folder: Int) -> Int {
        let id = nextID
        nextID += 1
        notes.append(Note(id: id, folder: folder, title: title, text: ""))
        return id
    }
}

/// A note in the list: its title and length side by side, or one above the
/// other at the accessibility text sizes.
struct NoteRow: View {

    let note: Note

    @Environment(.dynamicTypeSize) var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading) {
                Text(note.title)
                Text("\(note.text.count) characters")
            }
            .accessibilityIdentifier("note-\(note.title)")
        } else {
            HStack {
                Text(note.title)
                Spacer()
                Text("\(note.text.count) characters")
            }
            .accessibilityIdentifier("note-\(note.title)")
        }
    }
}

/// The note, and what the window is like.
struct NoteDetail: View {

    let note: Note

    @Environment(.horizontalSizeClass) var sizeClass

    @Environment(.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading) {
            Text(note.title)
                .font(.title)
                .accessibilityIdentifier("title")
            Text(note.text)
            Text(sizeClass == .compact ? "Narrow window" : "Wide window")
                .accessibilityIdentifier("width")
            Text(colorScheme == .dark ? "Dark" : "Light")
                .accessibilityIdentifier("scheme")
        }
        .padding()
        .navigationTitle(note.title)
    }
}

/// The sheet that adds a note, and closes itself.
struct NewNote: View {

    let notebook: Notebook

    let folder: Int

    let selection: Binding<Int?>

    @State var title = ""

    @Environment(.dismiss) var dismiss

    var body: some View {
        VStack {
            TextField("Title", text: $title)
            Button("Add") {
                selection.wrappedValue = notebook.add(title.isEmpty ? "Untitled" : title, to: folder)
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                dismiss()
            }
        }
        .padding()
    }
}

struct ContentView: View {

    let notebook: Notebook

    @State var folder: Int?

    @State var note: Int?

    @State var adding = false

    var body: some View {
        NavigationSplitView {
            List(notebook.folders, selection: $folder) { folder in
                Label(folder.name, systemImage: "folder")
            }
            .navigationTitle("Folders")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            if let folder {
                List(selection: $note) {
                    ForEach(notebook.notes(in: folder)) { note in
                        NoteRow(note: note)
                    }
                }
                .navigationTitle(notebook.name(of: folder))
                .toolbar {
                    Button("New Note") { adding = true }
                }
                .sheet(isPresented: $adding) {
                    NewNote(notebook: notebook, folder: folder, selection: $note)
                }
            } else {
                Text("Pick a folder")
            }
        } detail: {
            if let id = note, let note = notebook.note(id) {
                NoteDetail(note: note)
            } else {
                Text("Pick a note")
            }
        }
    }
}

struct ExampleNotesApp: App {

    let notebook = Notebook()

    var body: some Scene {
        WindowGroup {
            ContentView(notebook: notebook)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleNotesMain() -> rt_status {
    Runtime.main { ExampleNotesApp.run() }
}
