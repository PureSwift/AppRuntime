import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Shows a text for the user to edit, over as many lines as it has. It
/// takes the space it's offered and scrolls its own content.
///
/// For a note or a message, give it a binding, as in SwiftUI:
///
/// ```swift
/// TextEditor(text: $message)
/// ```
///
/// For a file, or anything the app edits from code, make a `TextBuffer`
/// and show that. The text then stays in the host, and only what the app
/// asks for crosses to it:
///
/// ```swift
/// TextEditor(buffer)
///     .font(.system(size: 14, design: .monospaced))
///     .autocorrectionDisabled()
/// ```
///
/// A `TextEditor` node has `buffer`, the identifier of the host's text
/// (`TextStorage.identifier()`), with `editable` and `wraps`. The host
/// puts its text view there; everything else about the text goes through
/// the `TextStorage` contract. When the node goes the text stays.
///
/// It's here and not in the SwiftUI frontend, where SwiftUI has it,
/// because an app declares every contract of the modules it links: in the
/// frontend, every app would ask its host for a text it never shows.
public struct TextEditor: View {

    let buffer: TextBuffer?

    let text: Binding<String>?

    let selection: Binding<TextSelection?>?

    let isEditable: Bool

    let wrapsLines: Bool

    /// The text of a view made from a binding, kept across updates.
    @State private var owned = OwnedText()

    /// `isEditable: false` still selects and scrolls. `wrapsLines: false`
    /// scrolls sideways.
    public init(_ buffer: TextBuffer, isEditable: Bool = true, wrapsLines: Bool = true) {
        self.buffer = buffer
        self.text = nil
        self.selection = nil
        self.isEditable = isEditable
        self.wrapsLines = wrapsLines
    }

    /// The whole text crosses to the app at each change: for a note or a
    /// message, not a file.
    public init(text: Binding<String>) {
        self.buffer = nil
        self.text = text
        self.selection = nil
        self.isEditable = true
        self.wrapsLines = true
    }

    public init(text: Binding<String>, selection: Binding<TextSelection?>) {
        self.buffer = nil
        self.text = text
        self.selection = selection
        self.isEditable = true
        self.wrapsLines = true
    }

    public var body: some View {
        _RenderNodeView("TextEditor", props: [
            "buffer": .int(Int(shown.identifier)),
            "editable": .bool(isEditable),
            "wraps": .bool(wrapsLines),
        ])
    }

    private var shown: TextBuffer {
        if let buffer {
            return buffer
        }
        return owned.show(text: text!, selection: selection)
    }
}

/// What's selected in a `TextEditor(text:selection:)`: SwiftUI's type. A
/// range of the string's own indices, or an insertion point.
///
/// SwiftUI's has a case for several ranges at once, which an editor here
/// doesn't have.
public struct TextSelection: Equatable, Hashable {

    public enum Indices: Equatable, Hashable {

        /// One range; empty is the caret.
        case selection(Range<String.Index>)
    }

    public var indices: Indices

    public init(range: Range<String.Index>) {
        indices = .selection(range)
    }

    public init(insertionPoint: String.Index) {
        indices = .selection(insertionPoint ..< insertionPoint)
    }

    /// Whether it's a caret, with nothing selected.
    public var isInsertion: Bool {
        switch indices {
        case .selection(let range): return range.isEmpty
        }
    }
}

/// A `TextEditor(text:)`'s own buffer, and what it and the binding last
/// agreed on.
final class OwnedText {

    private var made: TextBuffer?

    /// The text the binding and the buffer both have.
    private var synced = ""

    private var syncedSelection: TextSelection?

    private var text: Binding<String>?

    private var selection: Binding<TextSelection?>?

    /// Whether the buffer is being told what the binding says: what it
    /// reports back then isn't news.
    private var isPushing = false

    /// The buffer to show, brought up to date with the bindings.
    func show(text: Binding<String>, selection: Binding<TextSelection?>?) -> TextBuffer {
        self.text = text
        self.selection = selection
        let value = text.wrappedValue
        let buffer: TextBuffer
        if let made {
            buffer = made
            if value != synced {
                // The app changed the binding: a new text.
                synced = value
                isPushing = true
                buffer.string = value
                isPushing = false
            }
        } else {
            buffer = make(value)
        }
        if let selection {
            let wanted = selection.wrappedValue
            if wanted != syncedSelection {
                syncedSelection = wanted
                if case .selection(let range)? = wanted?.indices {
                    isPushing = true
                    buffer.selection = range.lowerBound.utf16Offset(in: synced) ..< range.upperBound.utf16Offset(in: synced)
                    isPushing = false
                }
            }
        }
        return buffer
    }

    private func make(_ value: String) -> TextBuffer {
        let buffer = TextBuffer(value)
        synced = value
        // The buffer holds these closures and this holds the buffer, so
        // they can't outlive it. Embedded Swift has no weak references.
        let owner = Unmanaged.passUnretained(self)
        buffer.onEdit = { _ in
            owner.takeUnretainedValue().edited()
        }
        buffer.onSelectionChange = { range in
            owner.takeUnretainedValue().selected(range)
        }
        made = buffer
        return buffer
    }

    private func edited() {
        guard !isPushing, let made else { return }
        let value = made.string
        guard value != synced else { return }
        synced = value
        text?.wrappedValue = value
    }

    private func selected(_ range: Range<Int>) {
        guard !isPushing, let selection else { return }
        let length = synced.utf16.count
        let lower = String.Index(utf16Offset: min(range.lowerBound, length), in: synced)
        let upper = String.Index(utf16Offset: min(range.upperBound, length), in: synced)
        let value = TextSelection(range: lower ..< upper)
        guard value != syncedSelection else { return }
        syncedSelection = value
        selection.wrappedValue = value
    }
}
