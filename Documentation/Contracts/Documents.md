# Documents

**Status:** a design for review. Nothing here is implemented, and the
names are proposals.

Module `DynamicDocuments`: the user's files. Choosing one to open, saving
one where the user says, keeping access to it for next time, and being
opened with one from another app.

| Contract | Kind | iOS | macOS | Android | Linux | Browser |
|---|---|---|---|---|---|---|
| `Documents` | contract, `requires: .userFiles` | `UIDocumentPickerViewController` | `NSOpenPanel`, `NSSavePanel` | the Storage Access Framework | the picker service the file manager owns | `showOpenFilePicker`, or `<input type="file">` |
| `DocumentGrant` | contract: one file or folder the user gave | a security-scoped URL | the same | a content URI and its permission | a descriptor from the picker service | a `FileSystemHandle`, or a `File` |
| `DocumentCallback` | callback: one operation's result | | | | | |
| `DocumentsDelegate` | callback: documents the app was opened with | `scene(_:openURLContexts:)` | `application(_:open:)` | `ACTION_VIEW` intents | launch services | the launch queue |

Guest-side Swift:

- **`DocumentPicker`**: asks the user for files, a folder, or a place to
  save.
- **`Document`**: a file or folder the user gave the app. It lasts as long
  as the app holds it.
- **`ContentType`**: a kind of file, by MIME type and extension.
  `UTType`'s place.
- `DocumentBookmark`, `DocumentAccess`, `DocumentExport`, `DocumentError`.
- `fileImporter` and `fileExporter`, SwiftUI's modifiers.

The render IR doesn't change: the host shows its own picker over the app's
window.

## What shapes it

- **The user picks, so nothing is asked.** No platform prompts for
  permission to show a picker. The user's choice of a file is the
  permission, for that file and no other.
- **A picked file is a place `Files` can reach.** A `Document` is a new
  `FileDirectory` value. Every `FileManager` call works on it, and so does
  every contract that takes a directory and a path, with no new methods:
  `MediaPlayer` already plays `.file(FilePath)`. See
  [Why not a file object](#why-not-a-file-object).
- **No path, no URL.** An Android document is a content URI with no path,
  a browser's is an object, and Linux's is a descriptor from outside the
  sandbox. The guest never sees where a document is; it has a name to
  show.
- **Access ends when the app lets go.** Platforms count open grants, so
  the host must know when one is finished with. A `Document` is an object,
  and releasing it ends the access.
- **Remembering is the host's job.** A browser's file handle can be stored
  only in the browser's own database, never as bytes. So the host keeps a
  remembered grant and the guest keeps a short string that names it.
- **Saving is exporting.** iOS has no picker that makes an empty file to
  write into. It takes a file the app already has and puts it where the
  user says. Every other platform can do that too, so that is the shape.

## For a guest

### Opening

```swift
import DynamicDocuments
import DynamicFiles

let picker = DocumentPicker()

// One photo, to look at.
if let photo = try await picker.open([.image]) {
    title = photo.name                                          // "IMG_0042.jpg"
    let bytes = try await FileManager.default.contents(at: photo.path)
}

// Several files, to change in place.
let notes = try await picker.open([.plainText], allowsMultiple: true, access: .readWrite)

// A folder of music.
if let library = try await picker.openFolder() {
    for name in try await FileManager.default.contentsOfDirectory(at: library.path) {
        player.load(.file(library.path / name))
    }
}
```

| `DocumentPicker` | Gives |
|---|---|
| `open(_:access:)` | a `Document`, or `nil` if the user cancelled |
| `open(_:allowsMultiple:access:)` | `[Document]`, empty if the user cancelled |
| `openFolder(access:)` | a folder `Document`, or `nil` |
| `export(_:suggestedName:)` | see [Saving](#saving) |
| `opened` | see [Opened with a document](#opened-with-a-document) |

- The calls are `async throws(DocumentError)`. Each has a
  completion-handler form, as `FileManager`'s do.
- Cancelling isn't an error. It is the ordinary way out of a picker.
- An empty list of types means any file.
- `access` is `.read` unless the app says `.readWrite`. Android decides it
  when the file is picked, and a browser asks the user about writing only
  during a user action, so a host can't add it later.
- **Call it from a user action.** A browser shows a picker only while
  handling a tap or a key, and refuses otherwise with `notAllowed`.
- **One picker at a time.** A second call while one is showing fails with
  `busy`.

### A document

| `Document` | |
|---|---|
| `name` | what the provider calls it, with its extension. For showing, not for finding it again |
| `kind` | `.file` or `.directory`, `Files`' `FileKind` |
| `contentType` | from the provider, where it says |
| `isWritable` | whether a write can succeed |
| `path` | a `FilePath`, for `FileManager` and any contract that takes one |
| `bookmark()` | see [Keeping access](#keeping-access) |

`path` is good while the `Document` object lives. When the app releases
the object the host ends the access, and a `FilePath` that outlives it
fails with `FileError.notPermitted`. Hold the document for as long as the
file is open in the app.

What `Files` does with a document's directory:

- **A file document** is its own empty path: `document.path` is the file.
  Any longer path fails with `notDirectory`.
- **A folder document** is a directory like the app's own: list it, read
  and write inside it, make and remove what's in it.
- **The document itself stays where it is.** `Files` can't remove, move or
  rename the picked file or folder: `invalidPath`, as for one of the app's
  own directories.
- **Copies cross over.** `copyItem(at: document.path, to: .caches / name)`
  brings a copy into the container.
- **A write to a read-only document** fails with `readOnly`.
- **A file a provider can't supply now**, such as a cloud file while
  offline, fails with `unavailable`. A read of one may take as long as a
  download.
- **A replacing write is atomic where the host can make it so.** Android's
  providers offer only truncate-and-write, so a crash there can leave part
  of a file.

### Saving

```swift
// Write it somewhere of the app's own, then ask where it goes.
let draft: FilePath = .temporary / "Untitled.txt"
try await FileManager.default.write(text, to: draft)

switch try await picker.export(draft, suggestedName: "Notes.txt") {
case .saved(let saved): document = saved      // later saves write to saved.path
case .savedCopy: break
case .cancelled: break
}
```

`export` shows the platform's save picker and copies the file there. It
gives a `DocumentExport`:

| Case | Means |
|---|---|
| `.saved(Document)` | saved, and the app may keep writing to it |
| `.savedCopy` | saved, and the host can't reach the copy again |
| `.cancelled` | the user cancelled |

`.savedCopy` is a browser without `showSaveFilePicker`, where saving is a
download. An editor treats its text as saved and still untitled.

The source is a file, never a folder, and must be in one of the app's own
directories or another document.

### Keeping access

```swift
// When the user opens something worth remembering:
let bookmark = try await document.bookmark()
defaults.set(bookmark.rawValue, forKey: "lastDocument")

// At the next launch:
let document = try await Document(resolving: DocumentBookmark(rawValue: saved))

// When the app drops it from its recents:
bookmark.forget()
```

- A `DocumentBookmark` is a short string the host made. It means nothing
  to another app or another device, and nothing after the app is removed.
- Resolving fails with `notFound` when the file is gone, and with
  `notPermitted` when the user or the system took the access back.
- **Forget what you no longer need.** Hosts may cap how many they keep, as
  Android does. A host at its cap fails `bookmark()` with `limitReached`.
- A host that can't remember fails with `unsupported`: a browser without
  the File System Access API, and Android for a document that arrived by
  open-with.

### Opened with a document

An app says in its manifest which files it opens (below). When the user
opens one with it, from the file manager or another app, the documents
arrive here:

```swift
for await documents in DocumentPicker.opened {
    open(documents)
}
```

- `opened` is an `EventStream<[Document], Never>`. Documents the app was
  launched with wait until the app first reads it.
- They are often read-only, and on Android they often can't be bookmarked.
- **`ApplicationDelegate.open(_:url:)` no longer receives files.** It
  stays for links and custom schemes. A file's URL was no use to a guest:
  it can't open a path outside its container.

### Content types

```swift
picker.open([.image])                         // any image
picker.open([.png, .jpeg])
picker.open([.plainText, ContentType(mimeType: "text/markdown", fileExtensions: ["md"])])
```

A `ContentType` is a MIME type, file extensions, or both. The constants
carry `UTType`'s names, so a SwiftUI call compiles as written:

| | Constants |
|---|---|
| Groups | `.item` (anything), `.image`, `.audio`, `.movie`, `.text`, `.folder` |
| Images | `.png`, `.jpeg`, `.gif`, `.webP`, `.heic`, `.svg` |
| Sound and video | `.mp3`, `.mpeg4Audio`, `.wav`, `.mpeg4Movie`, `.quickTimeMovie` |
| Text and data | `.plainText`, `.html`, `.json`, `.xml`, `.commaSeparatedText`, `.pdf`, `.zip` |
| Other | `.vCard`, `.calendarEvent` |

The frontend adds `typealias UTType = ContentType`.

### SwiftUI

```swift
.fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
    // Result<[Document], DocumentError>
}
.fileExporter(isPresented: $exporting, file: draft, defaultFilename: "Notes.txt") { result in
    // Result<Document?, DocumentError>: nil for a copy the app can't reach
}
```

- They differ from SwiftUI's in two places: a `Document` where SwiftUI
  gives a `URL`, and a `FilePath` to export where SwiftUI takes a
  `FileDocument`.
- Cancelling sets `isPresented` to `false` and calls nothing, as SwiftUI
  does.
- They live in `DynamicDocuments`, which depends on `DynamicSwiftUI` as
  `DynamicWebKit` does.

## The contract

```swift
@DynamicRuntime("org.pureswift.documents.Documents", requires: .userFiles)
protocol Documents {
    static func shared() -> Self

    /// `types`: see Content types on the wire. Empty: any file.
    /// `access`: 0 read, 1 read and write.
    func pick(_ types: [String], multiple: Bool, access: Int32, callback: DocumentCallback)     // didPick
    func pickFolder(_ access: Int32, callback: DocumentCallback)                                // didPick
    /// Copies the file to where the user says. `name` is the suggestion.
    func export(_ directory: Int32, path: String, name: String, callback: DocumentCallback)     // didPick, or didComplete
    func resolve(_ bookmark: String, callback: DocumentCallback)                                // didPick
    func forget(_ bookmark: String)

    /// Documents the app is opened with. The host keeps those that arrive
    /// before a delegate is set.
    func setDelegate(_ delegate: DocumentsDelegate?)
}

@DynamicRuntime("org.pureswift.documents.Grant")
protocol DocumentGrant {
    /// The value `Files` takes as a directory while this object lives.
    func directory() -> Int32
    func name() -> String
    /// 0 file, 1 directory.
    func kind() -> Int32
    /// A MIME type, where the provider gives one.
    func contentType() -> String?
    func isWritable() -> Bool
    func bookmark(_ callback: DocumentCallback)                                                 // didBookmark
}

@DynamicCallback("org.pureswift.documents.Callback")
protocol DocumentCallback {
    /// Empty: the user cancelled.
    func didPick(_ documents: [DocumentGrant])
    /// An export that saved, and left the app no grant.
    func didComplete()
    func didBookmark(_ bookmark: String)
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.documents.Delegate")
protocol DocumentsDelegate {
    func didOpen(_ documents: [DocumentGrant])
}
```

### Rules every host follows

- **One callback object per operation**, held until exactly one of its
  methods is called, on the main thread.
- **A grant's directory value is 256 or more.** The host picks it, and
  doesn't use it again in the same run. Values 0 to 4 stay the app's own
  directories.
- **Releasing the grant ends the access.** After that its directory value
  fails every `Files` call with `notPermitted`. Operations already running
  finish.
- **Every contract that takes a directory takes a grant's.** A host
  resolves directories in one place, so a media player or an image decoder
  given a document's directory reads the document.
- **The picker is the host's, over the app's window.** The guest's views
  don't receive input while it shows.
- **The types filter what can be picked.** Where a host can't filter by a
  type, it shows more, never fewer.
- **A folder grant covers what's inside it**, at any depth, and nothing
  outside. A link that leads out is `invalidPath`.
- **Bookmarks belong to the app.** One made by another app doesn't
  resolve.

### Content types on the wire

Each string is one of the forms HTML's `accept` attribute takes:

| Form | Example |
|---|---|
| a MIME type | `image/png` |
| a MIME group | `image/*` |
| an extension | `.gpx` |

The guest sends a type's MIME type when it has one, and its extensions
when it doesn't.

### Errors

`DocumentError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only, a cancelled task. The picker stays up and its result is dropped |
| 2 | `busy`: a picker is already showing |
| 3 | `notAllowed`: not called from a user action |
| 4 | `unsupported`: this host has no such picker, or can't remember grants |
| 5 | `notFound`: a bookmark's file is gone, or an export's source is |
| 6 | `notPermitted`: a bookmark's access was taken back |
| 7 | `limitReached`: the host keeps no more bookmarks |

`FileError` gains two cases, for `Files` calls on a document:

| Value | Case |
|---|---|
| 10 | `notPermitted`: the grant ended, or the provider refused |
| 11 | `unavailable`: the provider can't supply the file now |

## Changes to what exists

| Where | Change |
|---|---|
| `DynamicFiles` | `FileDirectory` becomes a struct with a raw value. The five directories are its static members, so `.documents / "a.txt"` reads as before and `allCases` is still the five; a switch over it needs a `default`. |
| `DynamicFiles` | `FileError` gains `notPermitted` and `unavailable`. |
| `RuntimeHost` | `HostFiles` gains grant directories: a host registers one for a path (Apple) or for a provider of descriptors (Linux), and removes it. |
| `Application` | Files stop arriving through `open(_:url:)`. |
| `AppManifest` | The `.userFiles` capability, and `documentTypes`. |
| Media, Drawing | Nothing for `MediaPlayer`. `DrawingImage` gains a load from a directory and a path, which it needs for the app's own files too. |

## The manifest

```swift
let app = App(
    …
    capabilities: [.userFiles],
    documentTypes: [
        .init(name: .localized("type.image"), types: ["image/*"], role: .viewer),
        .init(name: .localized("type.text"), types: ["text/plain", ".md"], role: .editor),
    ]
)
```

**`.userFiles`** has no usage text and no prompt, as `.audio` has none. It
exists so the packager and the sandbox know the app uses pickers:

| | `.userFiles` becomes |
|---|---|
| iOS | nothing |
| macOS | `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope` |
| Android | nothing |
| Linux | the picker service's socket, bound into the sandbox |
| Browser | nothing |

**`documentTypes`** says what the app opens. `types` are in the wire's
three forms. `role` is `.viewer` or `.editor`.

| | `documentTypes` becomes |
|---|---|
| iOS / macOS | `CFBundleDocumentTypes`, `LSSupportsOpeningDocumentsInPlace`, and an imported type declaration for a type the system doesn't know |
| Android | `ACTION_VIEW` intent filters by MIME type, with `ACTION_EDIT` for an editor. Android can't match by extension reliably, so a type given only by extension isn't registered |
| Linux | `MimeType=` in the `.desktop` file the packager writes, read by launch services |
| Browser | `file_handlers` in the web app manifest, for an installed app in a Chromium browser |

A manifest with `documentTypes` and no `.userFiles` is a build error.

## Per host

| | Notes |
|---|---|
| iOS | `UIDocumentPickerViewController(forOpeningContentTypes:)`, opening in place. A grant starts the URL's security scope and stops it on release. Reads and writes go through file coordination. A bookmark is the URL's bookmark data, kept in the host's own storage under the string. Export uses `forExporting` in its moving form on a copy the host makes, which is the form whose result the app can reach afterwards. **To be confirmed on a device.** |
| macOS | `NSOpenPanel` and `NSSavePanel`. Bookmarks are app-scoped security bookmarks. Outside the sandbox a grant is a plain path. |
| Android | `ACTION_OPEN_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`, `ACTION_CREATE_DOCUMENT`. Reads and writes use `ContentResolver`; a range read needs a seekable descriptor, and a provider without one is read through from the start. A bookmark is `takePersistableUriPermission` and the URI. A folder's paths are walked by display name through `DocumentsContract`. |
| Linux | Below. |
| Browser | Chromium: `showOpenFilePicker`, `showDirectoryPicker`, `showSaveFilePicker`; handles are kept in IndexedDB, and resolving one may ask the user again. Elsewhere: `<input type="file">` gives read-only files with no bookmarks and no folders, and export is a download. |

### Linux

The app's process is confined to `/app` and `/data` by its mount namespace
and by Landlock (`DynamicRuntime.md` §7.8). A picked file is outside both,
so no path can name it. A sketch, for the Linux host's own design:

- The file manager runs the **picker service**, outside any sandbox. An
  app with `.userFiles` gets its socket.
- The app's host asks for a pick; the service shows the picker as its own
  window above the app's, and answers with a **file descriptor** for each
  file, passed over the socket.
- Reads and writes use the descriptor. Landlock checks a file when it is
  opened, and the service did the opening.
- **A folder's files are opened by the service**, one request each. The
  app's host can't open them itself from a folder's descriptor, because
  that open is the app's and Landlock refuses it.
- An atomic replace is a temporary file and a rename, both by the service.
- The service keeps bookmarks, by app id, and is where a grant is taken
  back.
- Launch services hands an opened document to the app's host the same
  way.

The Landlock behaviour is from its documentation and needs a test.

This service is also what a Flatpak portal backend would call, so GTK apps
and AppRuntime apps show the same picker.

## Why not a file object

The other design is a `Document` contract with its own `read`, `write`,
`list` and `attributes`. It was set aside for three reasons:

- **It repeats `Files`:** eight operations, their rules for order,
  atomic writes, sizes and errors, and their tests.
- **Every other contract needs a second door.** `MediaPlayer` has
  `loadFile(directory, path)`; it would need `loadDocument` beside it, and
  so would an image decoder, a web view and an upload.
- **A folder needs paths anyway.** A music library is a folder and
  relative paths inside it, which is what a `FilePath` is.

What the chosen design costs is the change to `FileDirectory`, and one
oddity: a file document is a "directory" whose empty path is a file.

## Capability

`.userFiles`, which prompts for nothing (above).

## Threading

Every callback runs on the main thread (§6.4). Pickers are shown from it.

## Not in this design

- **Sharing** a file through the platform's share sheet, and **opening
  one in another app**. An email client needs both for attachments. They
  are a small contract of their own, since they hand a file out and this
  one takes files in.
- **Removing, renaming or moving the picked file itself.** A file manager
  does these, and the plan's file manager is a native app.
- **Watching** a document or a folder for changes made elsewhere.
- **Declaring a new file format** for other apps to recognise, beyond the
  MIME type and extensions a document type names.
- **Document-based apps:** SwiftUI's `DocumentGroup` and `FileDocument`,
  with their windows, titles and autosave.
- **Thumbnails** of a document, and its provider's icon.
- **Drag and drop** of files into a window.
- **Taking a photo or scanning a page** from the picker, which iOS and
  Android offer.

## Questions for review

1. **A document as a `FileDirectory` value**, with the change that makes
   to `DynamicFiles`, or a file object of its own.
2. **Names:** `DynamicDocuments`, `DocumentPicker`, `Document`,
   `ContentType`, and the capability `.userFiles`.
3. **A capability at all.** It prompts for nothing; it is there for the
   macOS entitlements and the Linux socket. The alternative is to grant
   both to every app.
4. **Saving as export only.** A new file is written to the container
   first. The alternative, a picker that returns an empty file to write,
   can't be built on iOS.
5. **Files leaving `ApplicationDelegate.open(_:url:)`**, which changes an
   implemented contract.
6. **Sharing and open-in-another-app:** in this module, or the separate
   one this design assumes.
