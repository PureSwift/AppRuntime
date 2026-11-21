import DynamicText

/// A text held in memory, with an undo history and nowhere to show it.
///
/// It's what `HostTextStorage` uses on a host with no `TextPlatform`: a
/// guest's buffers then load, edit, search, undo and save as anywhere, and
/// a `TextEditor` node shows nothing. It's also the contract's rules in
/// their plainest form, for a host writing an engine over its own text
/// view to compare with.
///
/// Main thread only.
public final class MemoryTextEngine: TextEngine {

    /// The text it reports to.
    public private(set) weak var storage: HostTextStorage?

    private var units: [UInt16] = []

    private struct Change {
        var location: Int
        var removed: [UInt16]
        var inserted: [UInt16]
        var selectionBefore: Range<Int>
        var selectionAfter: Range<Int>
    }

    private var undone: [Change] = []

    private var done: [Change] = []

    /// The range last asked to be scrolled into view.
    public private(set) var revealed: Range<Int>?

    public init(storage: HostTextStorage) {
        self.storage = storage
    }

    public var length: Int {
        units.count
    }

    public func text(in range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    public func setText(_ text: String) {
        let removed = units.count
        units = Array(text.utf16)
        done = []
        undone = []
        current = 0 ..< 0
        storage?.edited(at: 0, removed: removed, inserted: units.count)
        storage?.undoChanged(canUndo: false, canRedo: false)
        storage?.selectionChanged()
    }

    public func replace(_ range: Range<Int>, with text: String) {
        change(range, to: Array(text.utf16))
    }

    private var current = 0 ..< 0

    public var selection: Range<Int> {
        get { current }
        set {
            let lower = min(max(newValue.lowerBound, 0), units.count)
            let upper = min(max(newValue.upperBound, lower), units.count)
            guard lower ..< upper != current else { return }
            current = lower ..< upper
            storage?.selectionChanged()
        }
    }

    public var lineCount: Int {
        units.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    public func line(at location: Int) -> Int {
        units[..<min(max(location, 0), units.count)].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    public func lineStart(_ line: Int) -> Int? {
        guard line >= 0 else { return nil }
        if line == 0 { return 0 }
        var seen = 0
        for (index, unit) in units.enumerated() where unit == 0x0A {
            seen += 1
            if seen == line { return index + 1 }
        }
        return nil
    }

    public func undo() {
        guard let change = done.popLast() else { return }
        apply(location: change.location, removed: change.inserted.count, inserted: change.removed)
        undone.append(change)
        finish(selection: change.selectionBefore)
    }

    public func redo() {
        guard let change = undone.popLast() else { return }
        apply(location: change.location, removed: change.removed.count, inserted: change.inserted)
        done.append(change)
        finish(selection: change.selectionAfter)
    }

    public func reveal(_ range: Range<Int>) {
        revealed = range
    }

    // MARK: As the user

    /// Types `text` at the caret, in place of what's selected, as the
    /// user would: for a host's tests, and for a host that takes keys
    /// before it has a text view.
    public func type(_ text: String) {
        change(current, to: Array(TextCoding.normalizingLineBreaks(text).text.utf16))
    }

    /// Deletes what's selected, or the character before the caret.
    public func deleteBackward() {
        if !current.isEmpty {
            change(current, to: [])
        } else if current.lowerBound > 0 {
            // A surrogate pair goes whole.
            let end = current.lowerBound
            let start = end >= 2 && UTF16.isTrailSurrogate(units[end - 1]) && UTF16.isLeadSurrogate(units[end - 2]) ? end - 2 : end - 1
            change(start ..< end, to: [])
        }
    }

    // MARK: Changes

    /// One undo step.
    private func change(_ range: Range<Int>, to inserted: [UInt16]) {
        guard !range.isEmpty || !inserted.isEmpty else { return }
        let before = current
        let removed = Array(units[range])
        apply(location: range.lowerBound, removed: removed.count, inserted: inserted)
        let after = adjusted(before, location: range.lowerBound, removed: removed.count, inserted: inserted.count)
        done.append(Change(location: range.lowerBound, removed: removed, inserted: inserted, selectionBefore: before, selectionAfter: after))
        undone = []
        finish(selection: after)
    }

    private func apply(location: Int, removed: Int, inserted: [UInt16]) {
        units.replaceSubrange(location ..< location + removed, with: inserted)
        storage?.edited(at: location, removed: removed, inserted: inserted.count)
    }

    private func finish(selection: Range<Int>) {
        storage?.undoChanged(canUndo: !done.isEmpty, canRedo: !undone.isEmpty)
        if selection != current {
            current = selection
        }
        storage?.selectionChanged()
    }

    private func adjusted(_ selection: Range<Int>, location: Int, removed: Int, inserted: Int) -> Range<Int> {
        let lower = TextPositions.adjusting(selection.lowerBound, forEditAt: location, removed: removed, inserted: inserted)
        let upper = TextPositions.adjusting(selection.upperBound, forEditAt: location, removed: removed, inserted: inserted)
        return lower ..< max(lower, upper)
    }
}
