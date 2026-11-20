# Files

Module `DynamicFiles`: the app's own files, and the files in its bundle.
The guest's `FileManager`.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Files` | contract (no capability) | `FileManager` | `java.io.File` under `filesDir` and `cacheDir`; `AssetManager` for the bundle | the `/data` container; `/app/resources` | the origin's private file system; `fetch` for the bundle |
| `FileCallback` | callback: one operation's result | | | | |

Guest-side Swift: `FileDirectory`, `FilePath`, `FileAttributes`,
`FileError`, and `FileManager`, the async API app code uses.

The guest side is implemented, and so is the host side for any host with a
POSIX file system: `HostFiles` in `RuntimeHost`. The Darwin host registers
it on iOS and macOS, over the app's own directories (DarwinAppRuntime's
`DarwinFiles`), and the Linux host can register it as it is. Android and
the browser need their own. The design is §7.9 of `DynamicRuntime.md`.

## Why a contract is needed

A guest can't open a file today, in any mode:

- **A native slice has no file functions.** Its allowed libc set (§7.5) has
  `malloc` and `write`, and no `open`, so it links against glibc, musl and
  bionic alike.
- **The wasm2c shim's WASI has no files**, and WasmKit's bridge is given no
  directories.
- **A browser has no file system to give.** Its storage is asynchronous on
  the main thread, where the guest runs, so WASI's blocking `fd_read` can't
  be built on it.
- **The bundle isn't a directory everywhere.** An Android app's resources
  are inside the APK, read through `AssetManager`; a web app's are URLs.
  And `Bundle` (§7.4) only has strings and metadata: a guest can't read a
  shader or a level from its own bundle.

So files go through a contract, the same one in every mode, and WASI has
no files (§3.3).

## What shapes it

**Asynchronous, because of the web.** As with the model store: every
operation completes through a callback, and the guest API is `async`.

**Named directories, relative paths.** There's no path that means the same
thing on four platforms, and no `URL` in the guest. A file is a directory
the platform has a place for, plus a `/`-separated path inside it.

**Whole files, or ranges.** Most files an app handles are small: read and
write them whole, as bytes. A range read and an append cover the large
ones without a handle object to leak.

## Directories

| `FileDirectory` | For | Apple | Android | Linux | Browser | Kept |
|---|---|---|---|---|---|---|
| `documents` (0) | what the user made | Documents | `filesDir/Documents` | `/data/Documents` | OPFS `Documents` | backed up |
| `data` (1) | what the app needs and the user never sees | Application Support | `filesDir/Data` | `/data/Data` | OPFS `Data` | backed up |
| `caches` (2) | what can be made again | Caches | `cacheDir` | `/data/Caches` | OPFS `Caches` | the system may delete it when space is short |
| `temporary` (3) | this run only | `NSTemporaryDirectory` | `cacheDir/tmp` | `/tmp` | OPFS `Temporary` | emptied when the app next starts |
| `bundle` (4) | the app's resources | the bundle's resources | APK assets | `/app/resources` | the packaged resources' URLs | read-only |

- A path is relative, with `/` between components: `"levels/1.map"`. A
  leading `/`, `..`, an empty component, or a NUL fails with `invalidPath`.
  The empty path is the directory itself.
- Names are case-sensitive to the contract. On a case-insensitive volume
  (macOS, by default) two names that differ only by case are one file, so
  apps don't rely on either.
- Symbolic links aren't followed out of a directory, and can't be made.
- "Backed up" is the platform's own backup (iCloud, Android Auto Backup),
  where the user has it on. A browser backs up nothing, and may evict
  everything (see [Persistence](Persistence.md#where-its-kept)).

### The user's files

A file or folder the user picked is a directory too
([Documents](Documents.md)). Its value is 256 or more, chosen by the host,
and good while the app holds the `Document`:

- `FileDirectory` is a struct with a raw value, so it can hold one. The
  five above are its static members and its `allCases`; `isGrant` says
  whether a directory is a document.
- A picked file is its directory's empty path, with nothing under it. A
  picked folder is a directory like the five.
- What was picked stays where it is: its own empty path can't be removed
  or moved, and can be copied from.
- A directory the app doesn't hold, or holds no longer, answers
  `notPermitted`.

## For a guest

```swift
import DynamicFiles

let files = FileManager.default

let level = try await files.contents(at: .bundle / "levels/1.map")
try await files.write(saveData, to: .documents / "saves/slot1.sav")

for name in try await files.contentsOfDirectory(at: .documents / "saves") {
    print(name)
}
if try await files.fileExists(at: .caches / "thumbnails/42.png") { … }
try await files.removeItem(at: .caches / "thumbnails")
```

| `FileManager` | Does |
|---|---|
| `contents(at:)` | the whole file |
| `contents(at:offset:length:)` | part of it |
| `write(_:to:)` | replaces the file, atomically; makes the directories above it |
| `append(_:to:)` | adds to the end, creating the file |
| `contentsOfDirectory(at:)` | names in a directory; a directory's name ends in `/` |
| `attributesOfItem(at:)` | kind, size, modification date |
| `fileExists(at:)` | `attributesOfItem` without the throw |
| `createDirectory(at:)` | with the directories above it; fine if it exists |
| `removeItem(at:)` | a file, or a directory and all in it; fine if it's gone |
| `moveItem(at:to:)`, `copyItem(at:to:)` | fail if the destination exists |

The names follow Foundation's, so code reads the same; the calls are
`async throws(FileError)`, and take a `FilePath` where Foundation takes a
URL. Each has a completion-handler form, for code that isn't `async` and
for slices built without the concurrency runtime.

- A cancelled task stops waiting, with `cancelled`. The operation isn't
  undone, and may still happen.
- A `FilePath` drops one trailing `/`, so a name from a listing can be
  used as it is. `isValid` says beforehand whether a host will accept it.
- The class is named `FileManager`, as Foundation's is. Host-side Swift
  that imports both writes `DynamicFiles.FileManager`; a guest has no
  Foundation to confuse it with.

## The contract

```swift
@DynamicRuntime("org.pureswift.files.Files")
protocol Files {
    static func shared() -> Self

    /// `length` −1: to the end.
    func read(_ directory: Int32, path: String, offset: Int64, length: Int64, callback: FileCallback)   // didRead
    /// `mode`: 0 replace, 1 append.
    func write(_ directory: Int32, path: String, data: [UInt8], mode: Int32, callback: FileCallback)    // didComplete
    func list(_ directory: Int32, path: String, callback: FileCallback)                                 // didList
    func attributes(_ directory: Int32, path: String, callback: FileCallback)                           // didGetAttributes
    func makeDirectory(_ directory: Int32, path: String, callback: FileCallback)                        // didComplete
    func remove(_ directory: Int32, path: String, callback: FileCallback)                               // didComplete
    func move(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: FileCallback)
    func copy(_ directory: Int32, path: String, toDirectory: Int32, toPath: String, callback: FileCallback)
}

@DynamicCallback("org.pureswift.files.FileCallback")
protocol FileCallback {
    func didComplete()
    func didRead(_ data: [UInt8])
    /// Names, sorted; a directory's ends in "/".
    func didList(_ names: [String])
    /// `kind`: 0 file, 1 directory. `modified`: milliseconds since 1970 UTC, 0 if unknown.
    func didGetAttributes(kind: Int32, size: Int64, modified: Int64)
    func didFail(_ error: Int32)
}
```

### Rules every host follows

- **One callback object per operation**, held until exactly one of its
  methods is called, on the main thread.
- **Order.** Operations on the same path take effect in the order issued.
  Operations on different paths may run together.
- **A replacing write is atomic:** a reader sees the old file or the new
  one, never part of each, and a crash leaves one of them. (A temporary
  file and a rename; `createWritable` in a browser.)
- **Writes make missing directories**, and so do moves and copies, for
  their destination. Reads never do.
- **Removing the empty path** empties the directory, which stays. A
  directory itself can't be moved, copied or replaced: `invalidPath`.
- **A file where a directory is needed** on the way to a path is
  `notDirectory`; where the last directory would go, `alreadyExists`.
- **`bundle` is read-only:** writes, removes and moves from it fail with
  `readOnly`. Copies out of it work.
- **A read past the end** returns what's there: empty at or after the
  end.
- **Bytes are bytes.** No text encoding, line endings or Unicode
  normalization of contents. File names are UTF-8, and a host passes them
  as it's given them.

### Errors

`FileError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only |
| 2 | `notFound` |
| 3 | `alreadyExists`: a move's or copy's destination, or a file where a directory was to be made |
| 4 | `notDirectory`: a file where a directory is needed |
| 5 | `isDirectory`: a directory where a file is needed |
| 6 | `invalidPath` |
| 7 | `readOnly` |
| 8 | `outOfSpace` |
| 9 | `tooLarge`: more than this host passes in one call |
| 10 | `notPermitted`: a document the app doesn't hold, or a file the system won't let the host open |
| 11 | `unavailable`: a document its provider can't supply now, such as a cloud file while offline |

### Sizes

A read or a write is copied across the boundary whole, twice under a wasm
engine. A host accepts at least 64 MB in one call; past its limit it
answers `tooLarge`, and the guest uses ranges and `append`. Files of any
size can be listed, moved, copied and removed.

### A host with a POSIX file system

`HostFiles` (in `RuntimeHost`) is the whole contract over `open`, `pread`,
`rename` and the rest, with no Foundation. A host says where each directory
is and registers the module:

```swift
try HostFiles.configure(HostFiles.Configuration(directories: [
    .documents: container + "/Documents",
    .data: container + "/Library/Application Support",
    .caches: container + "/Library/Caches",
    .temporary: container + "/tmp",
    .bundle: bundle + "/resources",
]))
HostFilesModule.register(in: runtime)
```

- `configure` makes the writable directories and empties `temporary`.
- Work runs on a serial queue, and answers on the main dispatch queue. A
  host with a loop of its own passes `deliver`, to post answers to it.
- A path is confined to its directory: a symbolic link that leads out of
  it is `invalidPath`, for reads and writes alike.
- `maximumTransfer` is 256 MB unless the host says otherwise.
- **Grants.** `HostFiles.grant(_:)` takes a path, a kind and whether it's
  writable, and gives the directory `Files` reaches it by;
  `HostFiles.revoke(_:)` ends it. Operations already issued finish with
  the grants they started with. A replacing write to a granted file is
  atomic when a temporary file can be made beside it, and written over in
  place when it can't, as when the user gave the file and not its folder.
- **`HostFiles.path(of:path:)`** is where a file is, checked as `Files`
  checks it: for a media player, an image decoder, or any other contract
  that's handed a directory and a path.

### Per host

| | Notes |
|---|---|
| iOS / macOS | `HostFiles`, registered by DarwinAppRuntime's `DarwinFiles`. In a sandbox (always on iOS) the directories are the container's `Documents`, `Library/Application Support`, `Library/Caches` and `tmp`; a Mac app outside one gets its own folders under `~/Library/Application Support/<app id>`, `~/Library/Caches/<app id>` and the temporary directory. `bundle` is the app's resources, and `temporary` is emptied at launch. `documents` shows in the Files app only if the app's manifest asks for file sharing (a manifest option, later). |
| Android | `bundle` is the APK's assets: `AssetManager.open` and `list`. An asset has no modification date (0), and a compressed one must be read through to find its size. |
| Linux distro | `HostFiles`. The launcher already binds `/data` read-write and `/app` read-only (§7.8), and Landlock confines the host to them. `/tmp` is often another volume, which a move from `temporary` handles by copying. |
| Browser | `navigator.storage.getDirectory()`, one subdirectory per `FileDirectory`. Where a browser lacks asynchronous writes on the main thread, the host writes from a worker. `bundle` is `fetch` of the packaged resources; listing needs an index the packager writes beside them. `temporary` is emptied by the host at start. |

## Capability

None. These are the app's own directories and its own bundle. The user's
files are reached only through a document the user picked, and the picker
has the capability ([Documents](Documents.md)).

## Threading

Every callback runs on the main thread (§6.4). Hosts do the I/O elsewhere
and hop back.

## Example

`examples/ExampleFiles`: a notebook kept as text files. It reads a welcome
text from the bundle, saves, lists, opens and deletes notes in `documents`,
and exports them all with `async`/`await`. Its tests run it against
`HostFiles` and a temporary directory, checking the files on disk, as
`App.wasm` under WasmKit (`Packages/RuntimeWasm`) and as a sealed native
slice and wasm2c output (`Packages/LinkedSlice`). The Darwin host runs it
(DarwinAppRuntime's `DarwinFiles`).

## Not in this design

- **Choosing the user's files** is [Documents](Documents.md), around the
  platforms' pickers. What's picked is read and written here.
- **Passing a file to another contract** without copying its bytes through
  the guest: an HTTP download straight to a file, an upload from one, an
  image view of one, a web view of one. Each needs a parameter in that
  contract, taking a directory and a path, which the host resolves with
  `HostFiles.path(of:path:)`.
- Watching a directory for changes.
- Memory-mapped files, sparse files, permissions, extended attributes.
