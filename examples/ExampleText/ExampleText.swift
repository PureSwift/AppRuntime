import DynamicRuntime
import DynamicFiles
import DynamicText
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example text app: a small editor. It loads a text from its bundle
/// into a buffer the host holds, shows it in a `TextEditor`, says where
/// the caret is and whether there's anything to save, finds and replaces,
/// undoes, saves to the documents directory, and keeps a short note in a
/// second editor through a `String` binding.

/// The closures hold the editor, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Editor: @unchecked Sendable {

    /// The text being edited. The host holds it; this is a reference.
    @ObservationIgnored let buffer = TextBuffer()

    var query: String = ""

    var replacement: String = ""

    /// Edited through a binding: the whole text comes here at each change.
    var note: String = "Remember"

    var status: String = ""

    /// How many edits there have been, whoever made them.
    var edits: Int = 0

    static let saved: FilePath = .documents / "edited.txt"

    func start() {
        buffer.onEdit = { _ in
            self.edits += 1
        }
        buffer.load(.bundle / "welcome.txt") { result in
            switch result {
            case .success:
                self.status = "Opened welcome.txt"
            case .failure(.file(.notFound)):
                self.status = "No welcome.txt in the bundle."
            case .failure(let error):
                self.report("open", error)
            }
        }
    }

    func save() {
        buffer.save(to: Self.saved) { result in
            switch result {
            case .success:
                self.status = "Saved"
            case .failure(let error):
                self.report("save", error)
            }
        }
    }

    /// Selects the next match and scrolls to it.
    func findNext() {
        let query = self.query
        buffer.find(query, options: [.caseInsensitive, .wraps]) { match in
            guard let match else {
                self.status = "No \(query)"
                return
            }
            self.buffer.selection = match
            self.buffer.reveal(match)
            self.status = "Found at \(match.lowerBound)"
        }
    }

    func replaceAll() {
        buffer.replaceAll(query, with: replacement, options: [.caseInsensitive]) { count in
            self.status = "Replaced \(count)"
        }
    }

    /// At the caret, in place of what's selected.
    func insertRule() {
        buffer.insert("\n----\n")
    }

    func report(_ what: String, _ error: TextError) {
        status = "Couldn't \(what): error \(error.code.rawValue)"
    }
}

struct ContentView: View {

    let editor: Editor

    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editor.buffer.isModified ? "welcome.txt, edited" : "welcome.txt")
                .accessibilityIdentifier("title")
            Text(position)
                .accessibilityIdentifier("position")
            Text(format)
                .accessibilityIdentifier("format")
            TextEditor(editor.buffer)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($editing)
                .frame(height: 200)
            HStack(spacing: 8) {
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                Button("Undo") { editor.buffer.undo() }
                    .disabled(!editor.buffer.canUndo)
                Button("Redo") { editor.buffer.redo() }
                    .disabled(!editor.buffer.canRedo)
                Button("Rule") { editor.insertRule() }
                Button("Save") { editor.save() }
            }
            HStack(spacing: 8) {
                TextField("Find", text: Binding(get: { editor.query }, set: { editor.query = $0 }))
                    .accessibilityIdentifier("query")
                TextField("Replace", text: Binding(get: { editor.replacement }, set: { editor.replacement = $0 }))
                    .accessibilityIdentifier("replacement")
                Button("Find Next") { editor.findNext() }
                Button("Replace All") { editor.replaceAll() }
            }
            TextEditor(text: Binding(get: { editor.note }, set: { editor.note = $0 }))
                .frame(height: 60)
            Text("Note: \(editor.note)")
                .accessibilityIdentifier("note")
            Text(editor.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }

    /// Where the caret is, as an editor's status bar says it.
    var position: String {
        let buffer = editor.buffer
        let selection = buffer.selection
        let line = buffer.line(at: selection.lowerBound)
        let start = buffer.range(ofLine: line)?.lowerBound ?? 0
        let place = "Line \(line + 1), column \(selection.lowerBound - start + 1)"
        return selection.isEmpty ? place : "\(place), \(selection.count) selected"
    }

    var format: String {
        let buffer = editor.buffer
        let ending: String
        switch buffer.lineEnding {
        case .lf: ending = "LF"
        case .crlf: ending = "CRLF"
        case .cr: ending = "CR"
        }
        return "\(buffer.length) units, \(buffer.lineCount) lines, \(buffer.encoding.name), \(ending), \(editor.edits) edits"
    }
}

struct ExampleTextApp: App {

    let editor = Editor()

    init() {
        editor.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(editor: editor)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleTextMain() -> rt_status {
    Runtime.main { ExampleTextApp.run() }
}
