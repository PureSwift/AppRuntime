import DynamicRuntime

/// One text in the host, which the user edits in the platform's text view
/// (`Documentation/Contracts/TextEditor.md`). App code uses `TextBuffer`
/// and `TextEditor`, which wrap this contract.
///
/// The text is the host's. Typing, selecting, scrolling and the keyboard
/// never cross to the guest, which hears that a range changed and asks for
/// what it needs. Files are read into the text and written from it by the
/// host, off the main thread.
///
/// Positions and lengths are UTF-16 code units, and the text holds `\n`
/// as its only line break, on every host. A position that falls outside
/// the text or inside a surrogate pair is moved, never refused.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `UITextView` and its `NSTextStorage` |
/// | macOS | `NSTextView` |
/// | Android | `EditText` and its `Editable` |
/// | Linux | the host's own text view |
/// | Browser | a `<textarea>` |
@DynamicRuntime("org.pureswift.text.Storage")
public protocol TextStorage: AnyObject {

    /// An empty text. The host keeps `delegate` while the text lives, and
    /// destroys the text when the guest releases it.
    static func make(_ delegate: TextStorageDelegate) -> Self

    /// The longest text this host opens, in UTF-16 units.
    static func maximumLength() -> Int32

    /// Whether this host reads and writes an encoding, by its IANA name.
    static func supportsEncoding(_ name: String) -> Bool

    /// What a `TextEditor` node carries to say which text it shows.
    func identifier() -> Int32

    // MARK: Reading

    func length() -> Int32

    /// All of it.
    func text() -> String

    func substring(_ location: Int32, length: Int32) -> String

    /// At least 1.
    func lineCount() -> Int32

    /// The line a position is on, counting from 0.
    func line(_ location: Int32) -> Int32

    /// Where a line starts, or -1 past the last.
    func lineStart(_ line: Int32) -> Int32

    // MARK: Changing

    /// A new text: no undo history, the caret at the start, unmodified.
    func setText(_ text: String)

    /// One undo step, on the same history as the user's typing.
    func replace(_ location: Int32, length: Int32, text: String)

    func setSelection(_ location: Int32, length: Int32)

    func undo()

    func redo()

    func setModified(_ modified: Bool)

    /// Scrolls a range into view, where the text is shown.
    func reveal(_ location: Int32, length: Int32)

    // MARK: Files

    // A file as `Files` names it: a `FileDirectory` raw value and a path.

    /// Replaces the text with a file's, once it's read and decoded.
    /// `encoding` is an IANA name; empty takes the file's byte-order mark,
    /// or UTF-8. Answered by `didLoad` or `didFail`.
    func load(_ directory: Int32, path: String, encoding: String, callback: TextCallback)

    /// Writes the text as it is now. `lineEnding` is a `LineEnding` raw
    /// value. Answered by `didComplete` or `didFail`.
    func save(_ directory: Int32, path: String, encoding: String, lineEnding: Int32, byteOrderMark: Bool, callback: TextCallback)

    // MARK: Searching

    // `options` are bits of `TextSearchOptions`.

    /// The next match from `location`. Answered by `didFind`.
    func find(_ text: String, options: Int32, from location: Int32, callback: TextCallback)

    /// One undo step. Answered by `didReplace`.
    func replaceAll(_ text: String, with replacement: String, options: Int32, callback: TextCallback)
}

/// What happens to a text, from the host. Called on the main thread,
/// whoever caused the change: the user, the guest, or an undo.
@DynamicCallback("org.pureswift.text.StorageDelegate")
public protocol TextStorageDelegate: AnyObject {

    /// `removed` units at `location` became `inserted` units. `length` is
    /// the text's new length.
    func didEdit(_ location: Int32, removed: Int32, inserted: Int32, length: Int32)

    func didChangeSelection(_ location: Int32, length: Int32)

    /// Sent when the answer changes, not at every edit.
    func didChangeModified(_ modified: Bool)

    func didChangeUndo(_ canUndo: Bool, canRedo: Bool)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.text.Callback")
public protocol TextCallback: AnyObject {

    func didComplete()

    /// The encoding the file was read in, by its IANA name; its line
    /// ending, a `LineEnding` raw value; and whether it began with a
    /// byte-order mark.
    func didLoad(_ encoding: String, lineEnding: Int32, byteOrderMark: Bool)

    /// `location` is -1 when nothing matched.
    func didFind(_ location: Int32, length: Int32)

    func didReplace(_ count: Int32)

    /// `code` is a `TextError.Code` raw value. `file` is the `FileError`
    /// raw value when a file is why, and 0 otherwise.
    func didFail(_ code: Int32, file: Int32)
}
