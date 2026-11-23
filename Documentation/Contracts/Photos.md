# Photo library

**Status:** implemented in this repository: the guest side, the part of
the host side every host written in Swift shares, and the photo picker in
[Documents](Documents.md). No platform host has a photo library behind it
yet, and none draws a `Photo` node, so no real photo has been shown: the
tests keep the library in memory.

Module `DynamicPhotos`: the photos and videos the system keeps for the
user. PhotoKit's place.

An app meets the user's photos in three ways, and most need only the
lightest:

- **Adding one.** A camera saves what it took. It reads nothing.
- **Being given one.** The user picks a photo for a message or a profile.
  The system shows its own picker, and the app gets what was picked.
- **Browsing them.** A gallery shows them all, in order, with albums.

This design is the first and the third, and adds the second to
[Documents](Documents.md), where picking already lives. The three are
[compared](#the-library-the-photo-picker-and-the-document-picker) below.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Photos` | contract, `requires: .photoLibrary` | `PHPhotoLibrary` | `MediaStore` | the user's Pictures and Videos folders | a download, for adding; nothing else |
| `PhotoResults` | contract: one fetch's results | `PHFetchResult` | a `Cursor` | | |
| `PhotoFileGrant` | contract: one original, as a file | a `PHAssetResource` written out | a content URI | | |
| `PhotoCallback` | callback: one operation's result | | | | |
| `PhotosDelegate` | callback: the library changed | `PHPhotoLibraryChangeObserver` | a `ContentObserver` | | |

Guest-side Swift:

- **`PhotoLibrary`**: the library app code uses.
- **`PhotoAsset`**, **`PhotoAlbum`**: values.
- **`PhotoFetchResult`**: a list too long to hold, read as it's needed.
- **`PhotoFile`**: an asset's original, as a file.
- **`PhotoView`**: the SwiftUI view that shows an asset, at whatever size
  it's given.
- `PhotoLibraryAccess`, `PhotoKind`, `PhotoScaling`, `PhotoLibraryError`.

Host-side Swift, in `RuntimePhotos`: `HostPhotos`, the contract over a
host's `PhotoStore`; `PhotoFileFormat`, which tells a photo from a video
by a file's first bytes; and `MemoryPhotoStore`.

The render IR has one node for it, `Photo`.

## What shapes it

- **A library is tens of thousands of items.** Nothing lists them all to
  the guest. A fetch is a count and a way to ask for a few.
- **The pictures are the host's.** A grid of thumbnails is drawn by the
  host, from the system's own cache of them. No pixel crosses to the
  guest to show a photo.
- **An original is a file.** When an app needs the bytes, to play a
  video, to decode, to send, it asks for the asset as a file and gets a
  place `Files` can reach, as a picked document is. Every contract that
  takes a path then works with it, with no method of its own.
- **An original may not be here.** A library kept in the cloud holds
  small copies on the device. Asking for a file may mean a download.
- **The user may give a few, not all.** iOS and Android both let the user
  choose which photos an app sees. The library then holds those.
- **Deleting is the user's to confirm.** Both platforms ask the user,
  each time, before an app removes a photo it didn't make.
- **Adding needs less than reading.** So the manifest says which.

## For a guest

### Adding

```swift
import DynamicPhotos

let library = PhotoLibrary.shared
try await library.add(photo: .caches / "shot.jpg")
try await library.add(video: .caches / "clip.mp4")
```

- **The file is copied in.** The app keeps its own.
- **A photo is a JPEG, PNG or HEIC file; a video is MP4 or MOV.**
  Anything else fails with `invalidData`.
- **It gives the new `PhotoAsset`** to an app that may read the library,
  and `nil` to one that may only add.

### Access

| `PhotoLibrary` | |
|---|---|
| `access` | `.notDetermined`, `.denied`, `.restricted`, `.addOnly`, `.limited`, `.authorized`, `.unavailable`. Never asks |
| `requestAccess()` | asks the user if they haven't decided, for what the manifest declares |

- **`.addOnly` adds and reads nothing.** Every other call fails with
  `notAuthorized`.
- **`.limited` is the photos the user chose,** and what the app adds.
  Everything works on those.
- **A host that needs no leave to add** says `.addOnly` from the start.
  For an app that declared browsing, `requestAccess()` still asks then.
- **`allowsReading`** is true for `.authorized` and `.limited`;
  **`allowsAdding`** for those and `.addOnly`.
- **Adding doesn't ask by itself.** Without leave it fails with
  `notAuthorized`: ask first.

### Browsing

```swift
let recent = try await library.assets()                     // newest first
let videos = try await library.assets(of: .video)
let trip = try await library.assets(in: album)

recent.count                                                // 31 204
let first = try await recent.assets(in: 0..<60)             // [PhotoAsset]
```

| `PhotoAsset` | |
|---|---|
| `id` | the library's identifier for it. It lasts: an app may keep it |
| `kind` | `.image` or `.video` |
| `creationDate` | milliseconds since 1970 |
| `width`, `height` | pixels, upright |
| `duration` | seconds; 0 for an image |
| `isFavorite` | |

- **A `PhotoFetchResult` is a count and a window.** `assets(in:)` reads a
  range of it. A grid asks for the rows it shows.
- **Newest first,** always.
- **A fetch is a picture of the library when it was made.** After a
  change, fetch again.
- `library.asset(withID:)` is one asset, or `nil` when it's gone.

### Albums

```swift
let albums = try await library.albums()
```

| `PhotoAlbum` | |
|---|---|
| `id`, `title` | |
| `count` | how many it holds |
| `kind` | `.user` for one the user made, `.smart` for one the system keeps: Favourites, Videos, Screenshots |

Albums are read. Making one, and putting photos in one, isn't here.

### Showing

```swift
LazyVGrid(columns: columns) {
    ForEach(assets) { asset in
        PhotoView(asset)
            .frame(height: 110)
    }
}

PhotoView(asset, scaling: .fit)             // the whole picture, full screen
```

- **The host draws it,** at the size the view is given: a thumbnail in a
  grid, the full picture on a whole screen. It sharpens as a better copy
  arrives.
- **A video shows its first frame.** To play it, ask for its file.
- **It fills its space and crops,** unless told to fit.
- It takes the space it's offered. In a grid, give it a height.
- `PhotoView(assetID:)` shows an asset by an identifier the app kept.

### Originals

```swift
let file = try await library.file(for: asset)
player.load(.file(file.path))               // a video
try await FileManager.default.copyItem(at: file.path, to: .caches / "copy.jpg")
```

| `PhotoFile` | |
|---|---|
| `path` | a `FilePath`, for `FileManager` and any contract that takes one |
| `contentType` | a MIME type: `image/heic`, `video/quicktime` |
| `name` | the file's own name; `nil` where it has none |

- **`path` is good while the `PhotoFile` lives.** Releasing it ends the
  access, as with a [document](Documents.md#a-document).
- **Read-only.** A photo is changed by adding a new one.
- **It may take as long as a download.** A photo kept in the cloud is
  fetched first. Offline, that fails with `unavailable`.
- **It's the original,** in whatever format the camera made: HEIC,
  a 4K MOV. Not every host's decoder or player takes every one.

### Deleting

```swift
try await library.delete([asset])
```

- **The system asks the user first,** and says how many. Refusing fails
  with `cancelledByUser`. Android doesn't ask about photos the app added
  itself.
- **It's all of them or none.**

### Changes

```swift
for await _ in library.changes {
    reload()
}
```

The library says that something changed, not what: a photo taken, a
sync, another app. `library.onChange { … }` is the same with a closure.

### Errors

| `PhotoLibraryError` | |
|---|---|
| `notAuthorized` | no access, or not enough for this call |
| `unavailable` | this host has no library, or an original can't be fetched now |
| `notFound` | the asset, the album or the file is gone |
| `invalidData` | not a photo or a video the library takes |
| `cancelledByUser` | the user refused a deletion |
| `cancelled` | the task waiting was cancelled |

## The library, the photo picker and the document picker

| | Document picker | Photo picker | Photo library |
|---|---|---|---|
| Call | `DocumentPicker().open([.image])` | `DocumentPicker().open([.image], from: .photoLibrary)` | `PhotoLibrary.shared.assets()` |
| The user is asked for leave | no: picking is the leave | no: picking is the leave | yes, once, with a usage text |
| Capability | `.userFiles` | `.userFiles` | `.photoLibrary(.readWrite)` |
| Who draws the choice | the system: its file browser | the system: its photos screen | the app |
| What the app sees | the files picked | the photos picked | every photo, or those the user chose |
| What it gets | a `Document`: a file `Files` reaches | a `Document`, read-only | a `PhotoAsset`; a `PhotoFile` on request |
| Kept for next time | yes, with a bookmark | no | yes: the asset's `id` |
| Can it write there | yes, if asked | no | it can add and delete; not change |
| Albums, dates, favourites | no | no | yes |
| Hears of changes | no | no | yes |
| On a browser host | yes | yes: the same file input, which a phone's browser fills from its photos | adding only, as a download |

- **To put a picture in a message, a profile or a document, pick.** No
  leave is asked and nothing else is seen. That's nearly every app.
- **To let the user open an image as a file,** to edit and save it back,
  use the document picker.
- **To be the place photos are looked at,** use the library. Only a
  gallery, a camera's own roll or a backup tool needs it.

Why the photo picker is asked for apart from the document picker: on iOS
the two are different screens, and the document picker doesn't show the
user's photos at all. It shows Files. An app that asks for an image
there gets a file browser, where the user's photos aren't. Android's
document picker does show photos, and so does a Mac's open panel, but the
photo picker is the screen people know for this.

So [Documents](Documents.md) gains one method, and the picker one
parameter:

```swift
// Documents gains:

    /// Asks the user for photos or videos from their library, with the
    /// system's photo picker. `kinds`: bits, 1 images, 2 videos; none
    /// means both. Answers `didPick`, with nothing if the user cancelled.
    func pickPhotos(_ kinds: Int32, multiple: Bool, callback: DocumentCallback)
```

The types an app names say which
kinds: image types ask for images, video types for videos, and anything
else, or nothing, for both.

- **Each pick is a read-only `Document`,** a copy the host holds while
  the app holds the document. It can't be bookmarked: `unsupported`.
- **A host with no photo picker shows its document picker,** for images
  and videos. So `from: .photoLibrary` always works: a host written in
  Swift gets that from the contract's and the presenter's defaults until
  it has a photo picker of its own.
- **What's picked is read-only and not remembered,** whichever screen
  showed it and whatever access was asked for.
- **It needs nothing of this module:** no `.photoLibrary`, and no
  `DynamicPhotos`.

## The contract

```swift
@DynamicRuntime("org.pureswift.photos.Photos", requires: .photoLibrary)
public protocol Photos: AnyObject {

    static func shared() -> Self

    /// A `PhotoLibraryAccess` raw value. Never asks.
    func access() -> Int32
    /// Answered by `didChangeAccess`.
    func requestAccess(_ callback: PhotoCallback)

    func setDelegate(_ delegate: PhotosDelegate?)

    /// Copies a file into the library. A file as `Files` names it; `kind`
    /// is a `PhotoKind` raw value. Answered by `didAdd`.
    func add(_ directory: Int32, path: String, kind: Int32, callback: PhotoCallback)

    /// Newest first. `kind`: 0 both, or a `PhotoKind`. `album` empty: the
    /// whole library. Answered by `didFetch`.
    func fetch(_ kind: Int32, album: String, callback: PhotoCallback)
    /// Answered by `didFindAsset`: seven strings, or none.
    func asset(_ identifier: String, callback: PhotoCallback)
    /// Answered by `didListAlbums`.
    func albums(_ callback: PhotoCallback)

    /// The asset's original, as a file. Answered by `didOpenFile`.
    func file(_ identifier: String, callback: PhotoCallback)

    /// Asks the user, then deletes. Answered by `didComplete`.
    func delete(_ identifiers: [String], callback: PhotoCallback)
}

@DynamicRuntime("org.pureswift.photos.Results")
public protocol PhotoResults: AnyObject {
    func count() -> Int32
    /// The assets from `start`, `count` of them at most. Answered by
    /// `didListAssets`.
    func assets(_ start: Int32, count: Int32, callback: PhotoCallback)
}

@DynamicRuntime("org.pureswift.photos.File")
public protocol PhotoFileGrant: AnyObject {
    /// The directory `Files` takes for this file while the object lives:
    /// 256 or more. The file is the directory's empty path.
    func directory() -> Int32
    /// Empty where the file has none.
    func name() -> String
    func contentType() -> String
}

@DynamicCallback("org.pureswift.photos.Callback")
public protocol PhotoCallback: AnyObject {
    func didComplete()
    func didChangeAccess(_ access: Int32)
    /// The new asset's seven strings; none for an app that may only add.
    func didAdd(_ fields: [String])
    func didFetch(_ results: PhotoResults)
    /// Seven strings for each asset: identifier, kind, creation date,
    /// width, height, duration in milliseconds, and `1` for a favourite.
    /// Numbers are decimal.
    func didListAssets(_ fields: [String])
    func didFindAsset(_ fields: [String])
    /// Four strings for each album: identifier, title, count, kind.
    func didListAlbums(_ fields: [String])
    func didOpenFile(_ file: PhotoFileGrant)
    /// A `PhotoLibraryError` raw value.
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.photos.Delegate")
public protocol PhotosDelegate: AnyObject {
    func didChange()
}
```

An asset crosses as seven strings in a fixed order, and a page of them
as one array, so a grid's screenful is one call. [Contacts](Contacts.md)
cross the same way.

### Rules every host follows

- **Every answer is on the main thread, once.** The library is read off
  it.
- **A fetch is newest first, by creation date,** and doesn't change once
  made. `assets` past its end gives fewer, or none, and an asset that has
  gone since the fetch is left out of its page.
- **A page is read off the main thread,** as everything of the library
  is, so reading one is a call with an answer.
- **What a host sends badly is read safely:** a remainder of strings is
  left out, a number that isn't one is 0, and a kind from a newer host is
  an image, or an album the system keeps.
- **An identifier lasts** across launches, for as long as the asset
  does.
- **Sizes are the upright picture's.**
- **With limited access the library is the photos the user chose,** and
  what the app added. Nothing is said of the others.
- **An app that declared adding alone never reads,** whatever the user
  granted: not a fetch, not an album, not the identifier of what it
  added.
- **A file is the original, unchanged,** read-only, and good while the
  guest holds the `PhotoFile`. The host fetches it from the cloud if it
  must, and removes its own copy when the object is released.
- **Deleting goes through the system's own question,** wherever the
  system has one for it. The host never works round it.
- **`didChange` is sent after any change to the library,** this app's
  included, and not more than once for a burst of them.

## The render IR

| Type | Props | Children | Events |
|---|---|---|---|
| `Photo` | `asset` (string: an asset's identifier), `scaling` (`fill`, `fit`) | — | — |

Draw the asset in the node's bounds, from the system's thumbnails, at the
node's size in pixels or the next size up. Draw a smaller copy first if
there's one to hand, and replace it. A video is its first frame. An
asset the app may not see, or one that's gone, draws nothing. The node
has no events: a tap on it is an `onTapGesture`, as on any view.

## The shared host

`HostPhotos`, in `RuntimePhotos`, over a host's `PhotoStore`, which
works in the guest's own values:

```swift
public protocol PhotoStore: AnyObject, Sendable {    // off the main thread, one call at a time
    func add(fileAt path: String, kind: PhotoKind) throws(PhotoLibraryError) -> PhotoAsset
    /// The identifiers, newest first.
    func identifiers(of kind: PhotoKind?, in album: String?) throws(PhotoLibraryError) -> [String]
    func assets(withIDs identifiers: [String]) throws(PhotoLibraryError) -> [PhotoAsset]
    func albums() throws(PhotoLibraryError) -> [PhotoAlbum]
    /// The original, at an absolute path the host may read until
    /// `release` is called with it.
    func original(of identifier: String) throws(PhotoLibraryError) -> HostPhotoOriginal
    func release(_ original: HostPhotoOriginal)
}

HostPhotos.store = MyPhotoLibrary()
HostPhotos.allowsReading = true                    // RTCapabilityOptions.photoLibrary.access
HostPhotos.access = .notDetermined                 // what the platform says now
HostPhotos.requester = { completion in … }          // the platform's question
HostPhotos.deleter = { identifiers, completion in … }   // asks the user, then deletes
HostPhotosModule.register(in: runtime)

HostPhotos.libraryChanged()                        // from the platform
```

- **Access:** checked before every call, and before every page of a
  fetch made earlier. An app that declared adding alone has `addOnly` at
  most, whatever the user granted, and isn't told which asset it added.
  The user is asked once, and a requester that answers twice is heard
  once.
- **Adding:** the file is found through `HostFiles`, and must be what the
  call says it is by its first bytes (`PhotoFileFormat`): a JPEG, PNG or
  HEIC image, or an MP4 or QuickTime video.
- **Fetching:** it holds each fetch's identifiers and reads assets a page
  at a time, in the fetch's order whatever order the store gives.
- **Originals:** an original is a read-only grant in `HostFiles`, revoked
  when the guest lets go, and the store is then told to remove its copy.
- **Deleting:** the host's `deleter` asks the user and deletes. Nothing
  to delete asks nothing. Without a deleter, a deletion fails with
  `unavailable`.
- **Threads:** the store is called off the main thread in order, and
  every answer is on it.
- **Changes:** a burst of `libraryChanged` is one `didChange`, and this
  app's own additions and deletions are said too.
- **`MemoryPhotoStore`** is a library in memory, over bytes the test
  gives it, which writes an original out for as long as it's held. It is
  not a default. Without a store, every call fails with `unavailable`.

The host's renderer asks the platform for thumbnails itself. The shared
host has no part in drawing a `Photo` node.

## The manifest

```swift
capabilities: [.photoLibrary(.addOnly, usage: "Saves what you take to your photos.")]
capabilities: [.photoLibrary(.readWrite, usage: "Shows your photos and videos.")]
```

| | `.addOnly` | `.readWrite` |
|---|---|---|
| iOS / macOS | `NSPhotoLibraryAddUsageDescription` | `NSPhotoLibraryUsageDescription`, and the add text too |
| Android | nothing from Android 10; `WRITE_EXTERNAL_STORAGE` before | `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` and `READ_MEDIA_VISUAL_USER_SELECTED`; `READ_EXTERNAL_STORAGE` before Android 13 |
| Linux | the Pictures and Videos folders, for writing | the same, for reading and writing |
| Browser | nothing | nothing: there's no library to read |

The option reaches a host as `RTCapabilityOptions.photoLibrary.access`.

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS / macOS | PhotoKit. `PHPhotoLibrary.requestAuthorization(for: .addOnly)` or `.readWrite`; `.limited` is the contract's. `PHAsset.fetchAssets` sorted by `creationDate`, descending; `PHAssetCollection` for albums. `PHCachingImageManager.requestImage(for:targetSize:contentMode:)` for a `Photo` node, in its opportunistic mode, which gives a small copy and then a better one. `PHAssetResourceManager.writeData(for:toFile:)` with network access allowed for an original. `PHAssetChangeRequest.deleteAssets`, which the system confirms. `PHPhotoLibraryChangeObserver` for `didChange`. `PHPickerViewController` for the photo picker: it runs outside the app and needs no leave. |
| Android | `MediaStore.Files` rows with a media type of image or video, by `DATE_TAKEN`. `BUCKET_ID` and `BUCKET_DISPLAY_NAME` are the albums. `ContentResolver.loadThumbnail` for a `Photo` node. An original is the row's content URI. `MediaStore.createDeleteRequest` for deleting, which shows the system's question. From Android 14 the user may grant some photos and not all: that's `limited`. A `ContentObserver` for `didChange`. `ACTION_PICK_IMAGES` for the photo picker. |
| Linux | The user's Pictures and Videos folders, which the host scans and watches. A folder is an album. Thumbnails are the desktop's shared thumbnail cache. There's nothing to ask the user: the capability decides. The photo picker is the file manager's picker service, opened in those folders. |
| Browser | No library. `add` is a download. The photo picker is `<input type="file" accept="image/*,video/*">`. |

## Not in this design

- **Changing a photo:** edits, crops, adjustments kept beside the
  original. An app adds a new one.
- **Making albums,** putting photos in them, and marking a favourite.
- **Where a photo was taken,** and its other tags. Android asks for a
  separate leave to read a place. The file has them, for an app that
  reads tags.
- **Live Photos, bursts, and a photo's several forms.** A `PhotoFile` is
  the main one.
- **Changing which photos the user chose,** from the app. The system
  offers that itself.
- **Pixels for the guest without a file:** a thumbnail as bytes.
  [Drawing](Drawing.md) decodes a file.
- **Zooming and panning** a photo. That's a zooming scroll view, which
  the frontend doesn't have.
- **Shared albums, people, memories, search by what's in a picture.**
- **Hidden and recently deleted photos.**

## Example and tests

`examples/ExamplePhotos` is a gallery: it asks for access, shows the
newest photos in a grid a page at a time, lists the albums and shows one,
shows a photo large, opens its original as a file, deletes it with the
user's leave, and looks again when the library says it changed.
`examples/ExampleCamera` adds what it takes, with the add-only level, and
`examples/ExampleDocuments` takes a photo from the photo picker. Each
runs as `App.wasm` under WasmKit (`Packages/RuntimeWasm`) and as a sealed
native slice and wasm2c output (`Packages/LinkedSlice`), against
`HostPhotos` over a library in memory.

- `DynamicPhotosTests`: the contracts' keys and signatures, an asset and
  an album as strings and what a host sends badly, and the guest's
  `PhotoLibrary`, `PhotoFetchResult`, `PhotoFile` and `PhotoView` against
  a scripted host.
- `RuntimePhotosTests`: `HostPhotos` over `MemoryPhotoStore` and real
  files, from the guest: access and who is asked, an app that only adds,
  a file's format by its first bytes, a photo copied in, fetches and
  their pages, albums, limited access, an original read through `Files`
  and released, one in the cloud, deleting, and a burst of changes.
- `DynamicDocumentsTests` and `RuntimeDocumentsTests`: the photo picker,
  what's picked, and a host without one.
- `AppManifestTests` and `Scripts/test_manifest.py`: `.photoLibrary` and
  its two levels.

## Decided in review

The design was approved as drafted:

- **One capability with a level,** `.photoLibrary(.addOnly)` or
  `.photoLibrary(.readWrite)`.
- **Names:** `PhotoLibrary`, `PhotoAsset`, `PhotoAlbum`,
  `PhotoFetchResult`, `PhotoView`; contract `Photos`; module
  `DynamicPhotos`.
- **The host draws every photo,** in a `Photo` node.
- **An original is a file grant.**
- **The photo picker belongs to Documents,** as
  `open(from: .photoLibrary)`.
- **Deleting is in, changing isn't.** No favourites, albums or places to
  write.
- **No stand-in store.**

## Changed while building

- **A page of a fetch is asked for with a callback,** not returned. The
  draft's contract returned it, while its own guest example awaited it
  and its host read the library off the main thread. On Linux a page
  means opening files to learn their sizes.
- **`didAdd` carries the new asset,** not only its identifier, so adding
  is one call.
- **The contract protocol for an original is `PhotoFileGrant`.** Its wire
  name is `org.pureswift.photos.File`, as drafted; `PhotoFile` is the
  guest's class.
- **`HostPhotos.allowsReading`** is how a host says which level the
  manifest declared, as `HostContacts.allowsWriting` is.
- **A store's `add` always gives the asset.** The shared host decides
  whether the guest hears of it.

## What hosts still need

- **A `PhotoStore`** over PhotoKit in the Darwin host and over
  `MediaStore` in the Android host, with a `requester` and a `deleter`.
  Linux needs one over the user's Pictures and Videos folders.
- **A `Photo` node in each renderer,** drawn from the platform's
  thumbnails.
- **A photo picker:** `DocumentPresenter.pickPhotos` over
  `PHPickerViewController` on iOS, where the default, the document
  picker, doesn't show the user's photos; `ACTION_PICK_IMAGES` in the
  Android host, which implements `Documents` itself.
- **The packager's entries** for `.photoLibrary` and its level.
