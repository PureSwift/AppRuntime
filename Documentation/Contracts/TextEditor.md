# Text editing

**Status:** implemented in this repository: the guest side, and the part
of the host side every host written in Swift shares. No platform host has
a text view behind it yet, so no text has been shown or typed into: the
tests type into texts kept in memory.

Module `DynamicText`: a text the host holds and the user edits, and the
view that shows it. The text editor's file, a mail message being written,
a note.

A `TextField`'s content is a prop, sent whole each time it changes. That
suits a line and not a file of several megabytes, so here the text lives
in the host and the guest holds a reference to it, as it does to a web
page or a player.

| Contract | Kind | iOS | macOS | Android | Linux | Browser |
|---|---|---|---|---|---|---|
| `TextStorage` | contract (no capability) | `UITextView` and its `NSTextStorage` | `NSTextView` | `EditText` and its `Editable` | Cacao's text view | a `<textarea>` |
| `TextStorageDelegate` | callback: what happened to the text | the text view's and the storage's delegates | the same | a `TextWatcher`, a selection watcher | the view's own | `input` and `selectionchange` events |
| `TextCallback` | callback: one operation's result | | | | | |

Guest-side Swift:

- **`TextBuffer`**: the observable text app code uses.
- **`TextEditor`**: the SwiftUI view, for a buffer or for a `String`
  binding, with SwiftUI's `TextSelection`.
- `TextEncoding`, `LineEnding`, `TextSearchOptions`, `TextEdit`,
  `TextError`.

In the SwiftUI frontend: `@FocusState` with `focused`, and
`autocorrectionDisabled` and `textInputAutocapitalization`.

Host-side Swift, in `RuntimeText`: `HostTextStorage`, the contract over a
host's `TextPlatform` and its `TextEngine`s, with `TextCoding`,
`TextSearch` and `MemoryTextEngine`.

The render IR gains one node, `TextEditor`; two modifiers for the
keyboard; and focus, as a modifier and an event, which `TextField` gains
too.

## What shapes it

- **The text stays in the host.** Typing, scrolling, selecting, the
  keyboard, cut and paste, and the input method are the platform's text
  view's, and none of it crosses to the guest. The guest hears that
  something changed, not what was typed.
- **The guest asks for what it needs.** The length, the selection, a
  range of the text, the line a position is on. Reading the whole text is
  allowed and is the app's choice.
- **The file never passes through the guest.** The host reads a file into
  the buffer and writes the buffer to a file, off the main thread. A
  picked document is a `FilePath`, so it loads with no extra method.
- **The same text on every host.** Platforms differ over line breaks and
  over how they count. The buffer has one rule for each (below), so a
  position means the same thing everywhere.
- **Undo covers everyone's edits.** The user's typing and the app's
  `replace` are on one history, which the host keeps.
- **Plain text.** No styles, no colours. See
  [Not in this design](#not-in-this-design).

## For a guest

```swift
import SwiftUI
import DynamicText
import DynamicDocuments

let buffer = TextBuffer()
try await buffer.load(document.path)          // a picked Document

struct EditorView: View {

    let buffer: TextBuffer

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(buffer)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
            Text(buffer.isModified ? "Edited" : "Saved")
        }
    }
}

try await buffer.save(to: document.path)
```

### The buffer

| `TextBuffer` | |
|---|---|
| `init(_ text: String = "")` | a new text in the host |
| `length` | observable; in UTF-16 units ([Positions](#positions)) |
| `selection` | observable `Range<Int>`; empty is the caret. Settable |
| `isModified` | observable: changed since it was loaded, saved or made |
| `canUndo`, `canRedo` | observable |
| `isLoading` | observable: a `load` is under way |
| `string` | the whole text, copied out of the host. Setting it starts a new text |
| `substring(_:)` | a range of it |
| `encoding`, `lineEnding`, `hasByteOrderMark` | what `load` found, and what `save` writes |

- **A buffer is separate from where it's shown.** It loads and can be
  edited from code on screen or not, and keeps its text, selection and
  undo history while its view comes and goes. Releasing the `TextBuffer`
  destroys it.
- **It's made in the host when first used.** A buffer made with a text
  sends it then, with its line breaks already as the host will hold them.
- **One editor shows a buffer at a time.** If two name it, the later one
  has it.
- **`string` copies everything.** Fine for a note. For a large file,
  prefer `substring` and the host's own `save` and `find`.

### Loading and saving

```swift
try await buffer.load(.documents / "notes.txt")               // finds the encoding
try await buffer.load(document.path, encoding: .windows1252)   // or is told it

buffer.lineEnding = .lf                                        // convert on the next save
try await buffer.save(to: document.path)
```

- **`load` replaces the text** once the file is read and decoded. Until
  then the buffer keeps what it had. The undo history is emptied, the
  caret is at the start, and `isModified` is false.
- **`save(to:)` writes the text as it was when asked,** in the buffer's
  encoding and line ending. If nothing changed meanwhile, `isModified` is
  false when it completes. The write replaces the file as `Files` does.
- **The buffer doesn't remember a file.** The app holds the `Document` or
  the path and says where each time. A new, untitled text is saved by
  writing it to `.temporary` and exporting that
  ([Documents](Documents.md#saving)).
- Both are `async throws(TextError)`, with completion-handler forms.
- **One load at a time.** A second replaces the first, which fails with
  `cancelled`.
- **A host has a largest text it will open:**
  `TextBuffer.maximumLength`. A file that decodes to more fails with
  `tooLarge`. Desktop hosts take far more than phones.
- `buffer.markSaved()` clears `isModified` for an app that stores the
  text some other way.

### Encodings and line endings

| `TextEncoding` | |
|---|---|
| `.utf8`, `.utf16LittleEndian`, `.utf16BigEndian`, `.isoLatin1`, `.windows1252` | every host reads and writes these |
| `TextEncoding(name:)` | any other, by its IANA name (`"shift_jis"`); `isSupported` says whether this host has it |

- **`load` with no encoding** takes the file's byte-order mark if it has
  one, and UTF-8 otherwise. A file that is neither fails with
  `undecodable`. The host doesn't guess: the app asks the user, or tries
  `.isoLatin1`, which reads any bytes.
- **Bytes that aren't valid in the encoding fail the load.** They are not
  replaced, since a save would then destroy them.
- **A save fails with `unencodable`** when the text has a character the
  encoding lacks. Nothing is written.
- **A byte-order mark the file had is written back.**
- **The buffer holds `\n` only.** `load` turns `\r\n` and `\r` into `\n`
  and sets `lineEnding` to the file's first kind: `.lf`, `.crlf` or `.cr`.
  `save` writes that kind. A file that mixed them comes out with one.

### Positions

A position is a count of UTF-16 code units from the start of the text, as
`NSRange`, Java and JavaScript count. `"text".utf16.count` is a Swift
string's length in them. Ranges are `Range<Int>`.

- A position inside a surrogate pair is moved back to the pair's start.
- A range past the end is cut to the text.
- **Lines** count from 0 and end at `\n`:

| | |
|---|---|
| `lineCount` | at least 1 |
| `line(at:)` | the line a position is on |
| `range(ofLine:)` | that line's range with its line break, or `nil` past the end |

A column is `position - range(ofLine: line).lowerBound`.

### Editing from code

```swift
buffer.replace(4..<9, with: "hello")
buffer.insert("\t")                       // at the caret, replacing the selection
buffer.undo()
```

- **Each call is one undo step,** on the same history as the user's
  typing.
- **The selection follows the app's edits by one rule,** on every host. A
  position before the edit stays. One after what was replaced moves with
  the text. One inside it, or a caret where text is inserted, goes to the
  end of the new text.
- **`onEdit`** is called after every change, whoever made it, with a
  `TextEdit`: the range replaced and the length of what replaced it. Not
  the text itself, which may be a large paste; ask with `substring`.
  `buffer.edits` is the same as a stream.
- **`onSelectionChange`** is called when the selection moves, whoever
  moved it.
- **`reveal(_:)`** scrolls a range into view.

### Finding

```swift
if let match = await buffer.find("needle", options: [.caseInsensitive, .wraps]) {
    buffer.selection = match
    buffer.reveal(match)
}
let count = await buffer.replaceAll("colour", with: "color")
```

| | |
|---|---|
| `find(_:options:from:)` | the next match's range, or `nil`. Starts at the selection's end, or its start going backwards |
| `replaceAll(_:with:options:)` | how many were replaced. One undo step |
| `TextSearchOptions` | `.caseInsensitive`, `.backwards`, `.wholeWords`, `.wraps` |

The search is the host's, over text the guest doesn't hold. It matches
code units, with simple case folding for `.caseInsensitive`: no locale's
rules, and accents count. Characters outside the Basic Multilingual Plane
are compared as they are. `.wholeWords` wants no letter, digit or
underscore on either side. A cancelled task stops waiting, with `nil` or
0; a replacing still happens.

### The view

```swift
TextEditor(buffer)                              // editable, wraps lines
TextEditor(buffer, isEditable: false)           // selects and scrolls, no keyboard
TextEditor(buffer, wrapsLines: false)           // scrolls sideways
```

- It takes the space it's offered and scrolls its own content. Inside a
  `ScrollView`, give it a height.
- `font`, `foregroundColor` and `tint` apply to it. One font for the
  whole text.
- `.autocorrectionDisabled()` and `.textInputAutocapitalization(_:)` are
  SwiftUI's, and new here. They apply to `TextField` too.
- The host keeps the caret clear of the on-screen keyboard.
- **It's in `DynamicText`, not the SwiftUI frontend,** so an app imports
  that to use it, the binding form too. See
  [Decided in review](#decided-in-review).

### Focus

```swift
@FocusState private var editing: Bool

TextEditor(buffer)
    .focused($editing)

editing = true            // gives it the keyboard
```

SwiftUI's `@FocusState` and `focused`, new here and for `TextField` too.

- **Setting it true gives the view the keyboard,** and false puts the
  keyboard away. It follows the user: it becomes true when they tap into
  the text and false when they leave it.
- **`focused(_:equals:)`** is there for a form with several fields:
  `@FocusState var field: Field?`, and each view names its value.
- **True before the view is on screen** takes effect when it appears.

### A binding

```swift
TextEditor(text: $message)
TextEditor(text: $message, selection: $selection)      // Binding<TextSelection?>
```

SwiftUI's own forms. The view keeps a buffer of its own, reads the whole
text into the binding after each change, and starts a new text when the
binding is set to something else. For a note or a message, not a file.

`TextSelection` is SwiftUI's: a range of the string's own indices, or an
insertion point. The view converts between them and the buffer's
positions, which it can because the app holds the string. SwiftUI's case
for several ranges isn't here.

## The contract

```swift
@DynamicRuntime("org.pureswift.text.Storage")
public protocol TextStorage: AnyObject {

    /// An empty text. The host keeps `delegate` while it lives, and
    /// destroys the text when the guest releases it.
    static func make(_ delegate: TextStorageDelegate) -> Self
    /// The longest text this host opens, in UTF-16 units.
    static func maximumLength() -> Int32
    /// Whether this host reads and writes an encoding, by IANA name.
    static func supportsEncoding(_ name: String) -> Bool

    /// What a `TextEditor` node carries to say which text it shows.
    func identifier() -> Int32

    // Reading. Positions and lengths are UTF-16 units.
    func length() -> Int32
    func text() -> String
    func substring(_ location: Int32, length: Int32) -> String
    func lineCount() -> Int32
    func line(_ location: Int32) -> Int32
    /// Where a line starts, or -1 past the last.
    func lineStart(_ line: Int32) -> Int32

    // Changing.
    /// A new text: no undo history, the caret at the start, unmodified.
    func setText(_ text: String)
    /// One undo step.
    func replace(_ location: Int32, length: Int32, text: String)
    func setSelection(_ location: Int32, length: Int32)
    func undo()
    func redo()
    func setModified(_ modified: Bool)
    func reveal(_ location: Int32, length: Int32)

    // Files, as `Files` names them: a `FileDirectory` raw value and a path.
    /// `encoding` empty: the byte-order mark's, or UTF-8.
    /// Answered by `didLoad` or `didFail`.
    func load(_ directory: Int32, path: String, encoding: String, callback: TextCallback)
    /// Answered by `didComplete` or `didFail`.
    func save(_ directory: Int32, path: String, encoding: String, lineEnding: Int32,
              byteOrderMark: Bool, callback: TextCallback)

    // Searching. `options`: bits of `TextSearchOptions`.
    /// Answered by `didFind`.
    func find(_ text: String, options: Int32, from location: Int32, callback: TextCallback)
    /// Answered by `didReplace`.
    func replaceAll(_ text: String, with replacement: String, options: Int32, callback: TextCallback)
}

@DynamicCallback("org.pureswift.text.StorageDelegate")
public protocol TextStorageDelegate: AnyObject {
    /// `removed` units at `location` became `inserted` units. `length` is
    /// the text's new length.
    func didEdit(_ location: Int32, removed: Int32, inserted: Int32, length: Int32)
    func didChangeSelection(_ location: Int32, length: Int32)
    func didChangeModified(_ modified: Bool)
    func didChangeUndo(_ canUndo: Bool, canRedo: Bool)
}

@DynamicCallback("org.pureswift.text.Callback")
public protocol TextCallback: AnyObject {
    func didComplete()
    /// `lineEnding`: 0 `\n`, 1 `\r\n`, 2 `\r`.
    func didLoad(_ encoding: String, lineEnding: Int32, byteOrderMark: Bool)
    /// `location` is -1 when nothing matched.
    func didFind(_ location: Int32, length: Int32)
    func didReplace(_ count: Int32)
    /// `code`: a `TextError.Code`. `file`: the `FileError`, when that's why.
    func didFail(_ code: Int32, file: Int32)
}
```

`TextError`: `file(FileError)`, `undecodable`, `unencodable`,
`unsupportedEncoding`, `tooLarge`, `cancelled`, and `unknown` for a code
from a newer host.

### Rules every host follows

- **Everything is on the main thread,** and the reading methods answer at
  once from the text view's own storage. Files are read, decoded, encoded
  and written off it.
- **Every change is reported by `didEdit`,** once, whoever made it: the
  user, `replace`, `replaceAll`, `undo`, and `setText` and a finished
  `load` as one edit of everything. A `replaceAll` is one edit covering
  the first match to the last.
- **`didChangeModified` is sent when the answer changes,** not on every
  edit. Any edit sets it. `load`, `setText`, a `save` nothing followed,
  and `setModified(false)` clear it. Undoing back to the saved text
  doesn't.
- **`didChangeUndo` is sent when either answer changes.**
- **`didChangeSelection` is sent when the selection moves,** whoever moved
  it, once, and after the `didEdit` of an edit that moved it.
- **The guest's edits are undoable like typing.** `setText` and `load`
  empty the history.
- **The selection follows the guest's edits by the rule above,** whatever
  the platform's text view would do by itself.
- **The text holds `\n` only.** A paste or a `replace` with `\r\n` or
  `\r` is converted on the way in, and so is a search's text.
- **Positions are moved, never refused:** out of a surrogate pair to its
  start, and into the text.
- **A text is shown where a `TextEditor` node names it.** When the node
  goes the text stays. If two nodes name it, the later has it and the
  other is empty.
- **`find` and `replaceAll` may answer before they return,** or later.
  An empty search text matches nothing. A `find` going forwards gives the
  first match that starts at or after `location`; going backwards, the
  last that ends at or before it.
- **Input inside the node belongs to the text view:** pointers, keys,
  scrolling, the platform's editing menu and its shortcuts for cut, copy,
  paste, select all, undo and redo.
- **Releasing the `TextStorage` destroys the text** and cancels its load.

## The render IR

| Type | Props | Children | Events |
|---|---|---|---|
| `TextEditor` | `buffer` (int: a `TextStorage`'s `identifier()`), `editable` (bool), `wraps` (bool) | — | none here: the text reports through its contract |

| Kind | Args | Inherited |
|---|---|---|
| `autocorrection` | `disabled` (bool) | yes |
| `autocapitalization` | `mode` (`never`, `words`, `sentences`, `characters`); none: the platform's way | yes |
| `focused` | `value` (bool); report `focus` | no |

The two keyboard modifiers apply to `TextEditor`, `TextField` and
`Searchable`. A host without an on-screen keyboard ignores them.

**Focus.** A `focused` modifier is on a `TextEditor` or a `TextField`.

| Kind | Value | Payload |
|---|---|---|
| `focus` | 6 | whether the view now has the keyboard (bool) |

- When the user moves the keyboard into or out of the view, send `focus`.
- Sync it like a control: give or take the keyboard only when `value`
  differs from what was last rendered or reported. A node that appears
  with `value` true gets the keyboard then.
- At most one view has it. Giving it to one takes it from another, and
  that one reports `focus` false.

## The shared host

`HostTextStorage`, in `RuntimeText`, does what's the same on every
platform. A host supplies a `TextPlatform`, which makes a `TextEngine` per
text: its text view's storage.

```swift
public protocol TextEngine: AnyObject {              // main thread
    var length: Int { get }
    func text(in range: Range<Int>) -> String
    func setText(_ text: String)                     // empties the undo history
    func replace(_ range: Range<Int>, with text: String)
    var selection: Range<Int> { get set }
    var lineCount: Int { get }
    func line(at location: Int) -> Int
    func lineStart(_ line: Int) -> Int?
    func undo()
    func redo()
    func reveal(_ range: Range<Int>)
}

public protocol TextPlatform: AnyObject {
    func makeEngine(for storage: HostTextStorage) -> any TextEngine
    var maximumLength: Int { get }
    func supportsEncoding(_ name: String) -> Bool    // beyond the five
    var extraEncodings: TextCoding.Extra? { get }    // run off the main thread
}

HostTextStorage.platform = MyTextViews()
HostTextModule.register(in: runtime)

storage.edited(at: 4, removed: 5, inserted: 5)       // from the engine
storage.selectionChanged()
storage.undoChanged(canUndo: true, canRedo: false)

HostTextStorage.storage(for: identifier)?.engine     // for the renderer
```

An engine reports every change to its text with `edited`, whoever made
it, and converts what the user pastes with
`TextCoding.normalizingLineBreaks`. The positions it's given are already
inside the text and outside its surrogate pairs.

- **Files:** read and written off the main thread through
  `HostFiles.snapshot()`, which is `Files`' own reads and writes with the
  grants there were, so a picked document works. One load at a time. A
  file too long to fit isn't read.
- **Encodings:** `TextCoding` has the five every host has, the
  byte-order mark, and the refusal of invalid bytes. A platform adds
  others through `extraEncodings`.
- **Line endings:** found and converted on load, written on save, and
  converted in whatever the guest puts in.
- **Positions:** clamped and moved out of surrogate pairs before the
  engine sees them.
- **The selection after the guest's edit,** by `TextPositions`, said
  once.
- **`isModified`,** and when the delegate hears of it.
- **`find` and `replaceAll`:** `TextSearch`, over the engine's whole
  text, copied for each call.
- **Without a platform,** a text is a `MemoryTextEngine`: held in memory
  with an undo history, and shown nowhere. A guest's buffers then work on
  a host with no text view yet. It's also the rules in their plainest
  form, for a host writing its own engine to compare with.

## Capability

None. A buffer is memory. Its files are reached by `Files`' rules: the
app's own directories need nothing, and a document was the user's choice.

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS | `UITextView`. `NSTextStorageDelegate` gives each edit's range and change in length. `undoManager` for the history, with `NSUndoManagerDidCloseUndoGroup` and its neighbours for `didChangeUndo`. TextKit 2 lays out only what's visible, so long texts open quickly. The keyboard layout guide keeps the caret in view. No wrapping: a text container as wide as the longest line, in a view that scrolls sideways. |
| macOS | `NSTextView` in an `NSScrollView`, with `allowsUndo`. The same storage delegate. |
| Android | `EditText`. A `TextWatcher`'s `onTextChanged(start, before, count)` is `didEdit`. `EditText` has no undo an app can call, so the host keeps its own history from the watcher's edits. It lays out the whole text, so `maximumLength` is smallest there. |
| Linux | Cacao's text view, which the core apps plan asks to handle large files. Swift strings are UTF-8, so the view keeps each line's length in UTF-16 units to answer positions without scanning. |
| Browser | A `<textarea>`. Its `value` already has `\n` only, and `selectionStart` and `selectionEnd` are UTF-16 units. `setRangeText` for `replace`. A change from a script isn't on the browser's own undo history, so the host keeps its own and answers the `historyUndo` and `historyRedo` input events itself. `wrap="off"` for no wrapping. `TextEncoder` writes UTF-8 only, so the host encodes the other four. |

## Not in this design

- **Styled text:** fonts, colours and links for part of a text, and so
  syntax colouring and a rich-text composer. Mail in HTML is written in a
  web view.
- **Regular expressions.** Each platform has its own dialect, and one
  pattern doesn't mean the same on all of them.
- **Showing every match,** and the platform's own find bar where it has
  one. An app draws its bar and selects one match at a time.
- **A line-number gutter,** and a highlight for the current line.
- **Several edits as one undo step.** One `replace` of the whole range
  does for most.
- **More than one selection.**
- **Two views of one text.**
- **Noticing that the file changed on disk,** and saving by itself.
- **Guessing an encoding** beyond the byte-order mark.
- **Opening part of a file.** A text over `maximumLength` isn't opened.
- **Keyboard shortcuts and menu commands** for the app's own actions,
  such as Save and Find.
- **Focus for views that aren't text,** and moving it with the Tab key
  in an order the app sets.
- **What an input method is composing.** It's the text view's. An edit is
  reported as the platform's storage changes.

## Example and tests

`examples/ExampleText` is a small editor: it loads a text from its bundle,
says where the caret is and whether there's anything to save, finds and
replaces, undoes, saves, takes the keyboard with `@FocusState`, and keeps
a note through a binding. It runs as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`), against `HostTextStorage` over texts the test
types into.

- `DynamicTextTests`: the contracts' keys and signatures, and the guest's
  `TextBuffer` against a scripted host.
- `RuntimeTextTests`: `HostTextStorage` over texts in memory and real
  files, driven from the guest: editing, the selection, line breaks,
  surrogate pairs, loading and saving in each encoding, failures, a load
  replaced and a buffer released, searching, the views and their
  bindings, and `TextCoding` by itself.
- `DynamicSwiftUITests`: focus as state, and the keyboard's modifiers.

## Decided in review

The design was approved as drafted, with `@FocusState` and
`TextEditor(text:selection:)` added on the way. One proposal didn't
survive being built:

- **`TextEditor` is in `DynamicText`,** not the SwiftUI frontend. The
  draft put it in the frontend so `TextEditor(text:)` would compile with
  `import SwiftUI` alone, and said the cost hadn't been measured. Measured,
  it's this: an app declares every contract of the modules it links, and a
  host refuses an app that declares one it doesn't have. With the view in
  the frontend, every SwiftUI app declared the text contracts and no
  existing host would have run it. An app that edits text says
  `import DynamicText`.

The rest stand:

- **Names:** `TextBuffer`, `TextStorage`, module `DynamicText`.
- **Positions are UTF-16 units.**
- **`TextEditor(text:)` is built on a buffer in the guest,** so a host has
  one kind of editor.
- **No regular expressions.**
- **No guessing of encodings.**
- **`isModified` isn't cleared by undoing back to the saved text.**
- **Focus is SwiftUI's `@FocusState`,** in the render IR, and not a
  property of the buffer. `TextField` has it too.
