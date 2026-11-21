# Clipboard

**Status:** implemented in this repository: the guest side, and the part
of the host side every host written in Swift shares. The Darwin host
copies and pastes through `UIPasteboard` and `NSPasteboard`, and makes
`textSelection` text selectable (DarwinAppRuntime's `DarwinClipboard`).
Android, Linux and the browser need their own platform.

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
- `PasteboardImage`, `PasteboardImageType`, `PasteboardOptions`,
  `ClipboardKinds`, `PasteboardError`.

In the SwiftUI frontend: `textSelection(_:)`, SwiftUI's modifier, which
lets the user select and copy a `Text` with no code at all.

Host-side Swift, in `RuntimeClipboard`: `HostClipboard`, the contract
over a host's `ClipboardPlatform`, and `MemoryClipboard`.

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
  failure. Each takes a completion handler, and has an `async` form that
  throws `PasteboardError`, for an app that wants to say "Copied" only
  when it was. In `async` code the plain call is the `async` one, so it's
  written `try await`.
- **Call them from a user action.** A browser refuses otherwise, with
  `notAllowed`.

### Looking

```swift
pasteboard.hasStrings      // also hasURLs, hasImages
pasteboard.available       // ClipboardKinds: .text, .url, .image
```

- **Whether a read might give one.** It never asks or tells the user, and
  never sees the contents. `hasStrings` is true for a URL too, since
  `string()` gives its text.
- **A host that can't tell says yes.** A browser can't look without
  asking, so all three are true there.
- **It isn't observable.** It's read when the view updates, which is
  when the app comes to the front and at each change of its own.

### Pasting

```swift
let text = try await pasteboard.string()          // String?
let link = try await pasteboard.url()             // String?
let image = try await pasteboard.image()          // PasteboardImage?: data and type
let type = try await pasteboard.image(to: .caches / "pasted")   // PasteboardImageType?
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
  without the bytes crossing to the guest, replacing what's there, and
  says which of the two it wrote: a `PasteboardImageType`, `.png` or
  `.jpeg`, with its `mimeType` and `fileExtension`.

### Errors

| `PasteboardError` | |
|---|---|
| `notAllowed` | the user or the platform refused: not from a user action, the app isn't in front, the user said no, or a file the app may not read or write |
| `unsupported` | this host can't hold the kind: an image, on a host with text only |
| `invalidData` | not a PNG or a JPEG, a file that isn't there, or a path that isn't a file's |
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

`HostClipboard`, in `RuntimeClipboard`, does what's the same on every
platform. A host supplies a `ClipboardPlatform`:

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
    case image([UInt8], type: PasteboardImageType)   // PNG or JPEG
}

HostClipboard.platform = MyPasteboard()
HostClipboardModule.register(in: runtime)
```

A platform's `read` gives what's there of a kind, or `nil`. For text
where a URL is all there is, it gives the URL's text. An image it
converts to PNG, unless it's PNG or JPEG already.

- **Images:** it tells PNG from JPEG by the first bytes, on the way in
  and on the way out, and refuses anything else. It finds, reads and
  writes the files through `HostFiles.snapshot()`, off the main thread,
  so a picked document works.
- **Sizes:** it refuses more than `maximumSize`, which is `Files`' own
  default.
- **Answers:** once each, on the main thread. A platform that answers
  twice is heard once.
- **Without a platform,** it keeps a clipboard of the app's own, a
  `MemoryClipboard`. Copy and paste then work inside the app, and reach
  no other.

## Capability

None. No platform has a permission to declare for it: each guards a read
at the moment it happens, in its own way.

## Per host

From each platform's documentation, except where the Darwin host's was
tried, as said in its row.

| | Notes |
|---|---|
| iOS | `UIPasteboard.general`. `hasStrings`, `hasURLs` and `hasImages` for `available`: they don't alert. A read from code alerts from iOS 16 ("Allow Paste"), unless the user chose Allow under the app's Paste from Other Apps setting; a refusal reads as nothing, which the host reports as `notAllowed` when `available` said there was something. `setItems(_:options:)` with `.localOnly` for `sensitive`. An image is set as PNG or JPEG data by its type identifier. DarwinAppRuntime's `DarwinClipboard` does this. On the iOS Simulator a copy reached the system's pasteboard, looking didn't ask, and an image went from a file to the pasteboard and back to a file. The "Allow Paste" alert couldn't show there, so a read of another app's copy was refused, as `notAllowed`. |
| macOS | `NSPasteboard.general`. Nothing asks. `sensitive` adds `org.nspasteboard.ConcealedType`, which clipboard managers honour. An image held as TIFF is converted to PNG. DarwinAppRuntime's `DarwinClipboard`, tested on a pasteboard of the tests' own. |
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

## Example and tests

`examples/ExampleClipboard` copies a sum, a link, a code and its logo,
says what there is to paste without reading it, and pastes text, a link
and an image, the image into a file. It runs as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`), against `HostClipboard` over a clipboard the
test keeps.

- `DynamicClipboardTests`: the contracts' keys and signatures, and the
  guest's `Pasteboard` against a scripted host.
- `RuntimeClipboardTests`: `HostClipboard` over a clipboard the test
  fills and real files, driven from the guest: text and links, looking
  without reading, refusals, a platform that asks first or answers
  twice, sizes, images by bytes and by file, a picked document, and the
  `async` forms.
- `DynamicSwiftUITests`: `textSelection`.

The Darwin host's platform is written (DarwinAppRuntime's
`DarwinClipboard`), and was tried with `ExampleClipboard` on the iOS
Simulator, as the iOS row says. Whether a paste the user allows comes
through needs a device.

## Decided in review

The design was approved as drafted, so these stand:

- **Names:** `Pasteboard`, `Clipboard`, module `DynamicClipboard`.
- **No capability.**
- **Text, URLs and images only.**
- **No system paste button.** An app's own Paste button alerts on iOS
  each time, until the user allows the app in Settings.
- **No change count.**
- **`textSelection` is in.**
- **A host with no clipboard keeps one for the app.**

One thing changed in building it:

- **`image(to:)` gives a `PasteboardImageType`,** not the documents
  module's `ContentType`. An app declares every contract of the modules
  it links, so borrowing that type would have made every app that copies
  ask its host for the document pickers.
