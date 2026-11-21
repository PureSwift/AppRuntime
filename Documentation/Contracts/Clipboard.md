# Clipboard

**Status:** a design for review. Nothing here is implemented.

Module `DynamicClipboard`: copying and pasting from code. A calculator's
result, a browser's link, a contact's number, a photo.

Text views already copy and paste by themselves: a `TextField`, a
`TextEditor` and a web page have the platform's menu and shortcuts, and
none of that crosses to the guest. This is for the app's own Copy and
Paste buttons.

| Contract | Kind | iOS | macOS | Android | Linux | Browser |
|---|---|---|---|---|---|---|
| `Clipboard` | contract (no capability) | `UIPasteboard.general` | `NSPasteboard.general` | `ClipboardManager` | the compositor's selection, through the host's toolkit | `navigator.clipboard` |
| `ClipboardCallback` | callback: one operation's result | | | | | |

Guest-side Swift:

- **`Pasteboard`**: the clipboard app code uses. `UIPasteboard`'s place.
- `PasteboardImage`, `PasteboardOptions`, `PasteboardError`.
- `textSelection(_:)`, SwiftUI's modifier, which lets the user select and
  copy a `Text` with no code at all.

The render IR gains one modifier, `textSelection`.

## What shapes it

- **Reading is the sensitive half.** What's on the clipboard came from
  another app, and may be a password. Platforms guard it, each its own
  way: iOS asks the user, Android tells them, a browser refuses unless
  the user just acted. So a read is asynchronous, may be refused, and
  belongs in a button's action.
- **Looking isn't reading.** An app can learn that there's text to paste
  without seeing it, and without the user being asked or told. That's
  what enables a Paste button.
- **Writing is the easy half,** and still not certain: a browser allows
  it only while handling a tap or a key.
- **Few kinds.** Text, a URL and an image are what the planned apps copy.
  Every platform has those three, or near enough.
- **An image needn't pass through the guest.** A photo is tens of
  megabytes. It's copied from a file and pasted into one, by the host.
- **Nothing is declared.** No platform makes an app say in advance that
  it uses the clipboard.

## For a guest

```swift
import DynamicClipboard

let pasteboard = Pasteboard.general

// Copy.
Button("Copy") { pasteboard.setString(result) }

// Paste.
Button("Paste") {
    Task {
        if let text = try? await pasteboard.string() {
            input = text
        }
    }
}
.disabled(!pasteboard.hasStrings)
```

### Copying

| `Pasteboard` | Puts there |
|---|---|
| `setString(_:)` | text |
| `setURL(_:title:)` | a URL, as a URL where the platform has the kind, and as text everywhere. `title` is the text, when it isn't the URL itself |
| `setImage(_:type:)` | an image file's bytes: PNG or JPEG |
| `setImage(contentsOf:)` | an image file, by its `FilePath`: in the bundle, the app's files, or a document |
| `clear()` | nothing |

- **A write replaces everything** that was there.
- **Each takes `options:`.** `.sensitive` is for a password or a code:
  the platform keeps it out of previews, clipboard history and other
  devices, where it can.
- **They don't wait.** The calls above return at once and drop a
  failure. Each has a form with a completion handler, and an `async` one
  that throws `PasteboardError`, for an app that wants to say "Copied"
  only when it was.
- **Call them from a user action.** A browser refuses otherwise, with
  `notAllowed`.

### Looking

```swift
pasteboard.hasStrings      // also hasURLs, hasImages
```

- **Whether a read might give one.** It never asks or tells the user, and
  never sees the contents.
- **A host that can't tell says yes.** A browser can't look without
  asking, so all three are true there.
- **It isn't observable.** It's read when the view updates, which is
  when the app comes to the front and at each change of its own.

### Pasting

```swift
let text = try await pasteboard.string()          // String?
let link = try await pasteboard.url()             // String?
let image = try await pasteboard.image()          // PasteboardImage?: data and type
let type = try await pasteboard.image(to: .caches / "pasted")   // ContentType?
```

- **`nil` means there isn't one.** That isn't an error.
- **They are `async throws(PasteboardError)`,** with completion-handler
  forms.
- **The user may be asked, or told.** iOS asks before each read, unless
  the user allowed the app in Settings. Android shows a note that the app
  pasted. Refusing gives `notAllowed`.
- **Call them from a user action,** with the app in front. A browser,
  Android and Linux refuse otherwise, with `notAllowed`.
- **`string()` gives a URL's text** when a URL is all there is.
- **`url()` gives a URL only when the clipboard says it's one.** Text
  that happens to be a URL is text. A browser has no such kind, so there
  `url()` is always `nil`: read the string.
- **An image arrives as PNG or JPEG,** whatever it was. `image()` is for
  a small one, such as a contact's photo. `image(to:)` writes the file
  without the bytes crossing to the guest, and says which of the two it
  wrote.

### Errors

| `PasteboardError` | |
|---|---|
| `notAllowed` | the user or the platform refused: not from a user action, the app isn't in front, or the user said no |
| `unsupported` | this host can't hold the kind: an image, on a host with text only |
| `invalidData` | not a PNG or a JPEG, or a file that isn't there |
| `tooLarge` | more than the host passes in one call: use the file forms |
| `cancelled` | the task waiting was cancelled |

### Selecting text

```swift
Text(contact.phone)
    .textSelection(.enabled)
```

SwiftUI's modifier, new here. The user selects the text and copies it
with the platform's own menu. It's inherited, and
`.textSelection(.disabled)` turns it off for part of a tree. It needs no
contract, and nothing reaches the guest.

## The contract

```swift
@DynamicRuntime("org.pureswift.clipboard.Clipboard")
public protocol Clipboard: AnyObject {

    static func shared() -> Self

    /// What a read might give: bits, 1 text, 2 a URL, 4 an image. It
    /// never asks or tells the user. A host that can't tell says 7.
    func available() -> Int32

    // Each write replaces everything. `options`: bits, 1 sensitive.
    // Answered by `didComplete` or `didFail`.

    func clear(_ callback: ClipboardCallback)
    /// `url` empty: text alone. Otherwise the URL, with `text` as its text.
    func writeText(_ text: String, url: String, options: Int32, callback: ClipboardCallback)
    func writeImage(_ data: [UInt8], mimeType: String, options: Int32, callback: ClipboardCallback)
    /// A file as `Files` names it: a `FileDirectory` raw value and a path.
    func writeImageFile(_ directory: Int32, path: String, options: Int32, callback: ClipboardCallback)

    // Answered by the matching `didRead…`, or `didFail`.

    func readText(_ callback: ClipboardCallback)
    func readURL(_ callback: ClipboardCallback)
    func readImage(_ callback: ClipboardCallback)
    func readImageToFile(_ directory: Int32, path: String, callback: ClipboardCallback)
}

@DynamicCallback("org.pureswift.clipboard.Callback")
public protocol ClipboardCallback: AnyObject {
    func didComplete()
    /// Text, or a URL. `nil` when there's none.
    func didReadText(_ text: String?)
    /// `image/png` or `image/jpeg`. An empty type: there's no image.
    func didReadImage(_ data: [UInt8], mimeType: String)
    /// The type of the file written. Empty: there's no image, and no file.
    func didWriteImageFile(_ mimeType: String)
    /// A `PasteboardError` raw value.
    func didFail(_ error: Int32)
}
```

### Rules every host follows

- **Every answer is on the main thread, once.** It may come before the
  call returns, or after a prompt.
- **A write replaces everything.** A URL is written as the platform's
  URL kind where it has one, and as text always. An image is written
  alone.
- **`available` never asks, tells or reads.** It answers from what the
  platform says is there.
- **A read gives what's there and nothing made up.** No text is `nil`,
  not an empty string. Text is given as it is: its line endings aren't
  changed.
- **`readText` gives a URL's text** when the clipboard has a URL and no
  text.
- **`readURL` doesn't parse text.**
- **A written image is PNG or JPEG,** told by its first bytes, not by the
  type the guest gave. Anything else is `invalidData`.
- **A read image is PNG or JPEG.** The host converts what the platform
  holds otherwise, to PNG.
- **Files are found as `Files` finds them,** so a picked document works,
  and are read and written off the main thread.
- **`sensitive` is honoured where the platform can,** and ignored where
  it can't. It never fails a write.
- **A refusal is `notAllowed`,** whether the platform refused or the
  user did.

## The render IR

| Kind | Args | Inherited |
|---|---|---|
| `textSelection` | `enabled` (bool) | yes |

It applies to `Text` and `Label` nodes. The host lets the user select
their text and copy it with the platform's own menu and shortcuts. A
host that can't shows the text as it would have.

## The shared host

`HostClipboard`, in a new `RuntimeClipboard`, does what's the same on
every platform. A host supplies a `ClipboardPlatform`:

```swift
public protocol ClipboardPlatform: AnyObject {       // main thread
    func available() -> ClipboardKinds
    func clear()
    func write(_ content: HostClipboardContent, isSensitive: Bool,
               completion: @escaping (PasteboardError?) -> Void)
    func read(_ kind: ClipboardKind,
              completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void)
}

public enum HostClipboardContent {
    case text(String, url: String?)
    case image([UInt8], type: ContentType)           // PNG or JPEG
}
```

- **Images:** it tells PNG from JPEG, refuses anything else, and finds,
  reads and writes the files through `HostFiles`, off the main thread.
- **Sizes:** it refuses more than `HostFiles`' largest transfer.
- **Answers:** once each, on the main thread.
- **Without a platform,** it keeps a clipboard of the app's own, in
  memory. Copy and paste then work inside the app, and reach no other.

## Capability

None. No platform has a permission to declare for it: each guards a read
at the moment it happens, in its own way.

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS | `UIPasteboard.general`. `hasStrings`, `hasURLs` and `hasImages` for `available`: they don't alert. A read from code alerts from iOS 16 ("Allow Paste"), unless the user chose Allow under the app's Paste from Other Apps setting; a refusal reads as nothing, which the host reports as `notAllowed` when `available` said there was something. `setItems(_:options:)` with `.localOnly` for `sensitive`. An image is set as PNG or JPEG data by its type identifier. |
| macOS | `NSPasteboard.general`. Nothing asks. `sensitive` adds `org.nspasteboard.ConcealedType`, which clipboard managers honour. An image held as TIFF is converted to PNG. |
| Android | `ClipboardManager`. `ClipData.newPlainText` and `newRawUri`. `getPrimaryClipDescription()` for `available`: it shows no note. A read shows the system's note from Android 12, and from Android 10 works only while the app has focus. An image is a content URI: the host copies it to its cache and serves it from a `FileProvider`, and reads one through the `ContentResolver`. `ClipDescription.EXTRA_IS_SENSITIVE` for `sensitive`, from Android 13. |
| Linux | The compositor's selection, through the host's toolkit: `text/plain;charset=utf-8`, `text/uri-list` and `image/png`. On Wayland an app reads the selection only while it has keyboard focus, and what it copied goes when it exits unless a clipboard manager kept it. `x-kde-passwordManagerHint` for `sensitive`. |
| Browser | `navigator.clipboard`, in a secure context. `writeText`, `readText`, and `write` and `read` with `ClipboardItem`s. Both need a user action, and a read asks. Images are `image/png` only, so the host converts a JPEG through a canvas. There is no URL kind: a URL is written as text. `available` is always 7. Where the API is missing, every call is `notAllowed`. |

## Not in this design

- **Rich text and HTML.** A text view and a web page copy their own.
- **Files, and kinds of an app's own.**
- **Several items at once,** and several forms of one item beyond a URL
  with its text.
- **Knowing when the clipboard changes:** a change count, a
  notification. The platforms differ too much: a browser has nothing.
- **A copy that expires,** as iOS can make one.
- **The system's paste button,** which on iOS pastes without the alert,
  because the system drew the button and saw the tap. See the questions.
- **Drag and drop,** which shares the platforms' machinery and little
  else.
- **The primary selection** on Linux: the middle-click paste.
- **A share sheet.** That's with [Documents](Documents.md).

## Questions for review

1. **Names:** `Pasteboard` for the guest's class, as UIKit and AppKit
   have it; `Clipboard` for the contract; module `DynamicClipboard`.
2. **No capability.** The alternative is one with no platform behind it,
   so a store listing could say an app reads the clipboard.
3. **Text, URLs and images only.** HTML is the next kind to add, for a
   mail composer that isn't a web view.
4. **No system paste button in the first version.** It would be a
   `PasteButton` node the host draws with `UIPasteControl`, and it's the
   only way past iOS's alert. Without it, an app's own Paste button
   alerts on iOS each time, until the user allows the app in Settings.
5. **No change count.** An app can't tell that what it copied is still
   there, or that something new arrived.
6. **`textSelection` is in,** though it needs no contract: it's the
   other half of "let the user copy this".
7. **A host with no clipboard keeps one for the app,** in memory. The
   alternative fails every call with `unsupported`.
