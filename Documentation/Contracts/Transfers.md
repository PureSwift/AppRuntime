# Transfers

**Status:** a draft for review. Nothing here is implemented.

Module `DynamicTransfers`: downloading to a file and uploading from one,
with the host moving the bytes. A transfer can be left to the system, which
carries it on after the app is closed.

`HTTPClient.md` leaves both out of its first version. Today a download
arrives in the guest a chunk at a time, and the guest writes each chunk
through `Files`. That is two crossings for every chunk, a copy of the file
through the guest's memory, and nothing at all once the app has gone. An
offline map is hundreds of megabytes; a browser's download may be a disk
image.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Transfers` | contract, `requires: .network` | `URLSession`, and a background session for what's carried on | OkHttp to a file; a user-initiated data transfer job, or `DownloadManager`, for what's carried on | `URLSession` in the host; the host's transfer service for what's carried on | `fetch` to the origin's private files; Background Fetch where there is one |
| `TransferCallback` | callback: one operation's result | | | | |
| `TransfersDelegate` | callback: a transfer changed | | | | |

Guest-side Swift:

- **`TransferManager`**: the app's transfers. It starts them, and lists
  those the system has carried on or finished.
- **`Transfer`**: one of them, observable: its state and how far it has
  got.
- `TransferRequest`, `TransferOptions`, `TransferResponse`,
  `TransferState`, `TransferError`.

Host-side Swift, in `RuntimeTransfers`: `HostTransfers`, the contract
over a host's `TransferEngine`, and `MemoryTransferEngine`.

The existing contracts don't change, and neither does the render IR.

## What shapes it

- **The bytes stay in the host.** A download goes from the network to a
  file, and an upload from a file to the network. The guest names the
  file and hears how far it has got.
- **A transfer can outlive the app.** Then there is nothing in the guest
  to call back: the delegate object died with it. So a transfer is
  something the host keeps, with an identifier, and the app asks what
  there is when it next runs.
- **What outlives the app has to be written down.** The host stores the
  request to carry it on. So a request is a URL, a method and headers:
  plain values, with no object behind them and no body in memory.
- **The system decides when.** On every platform a transfer left to the
  system runs when it suits the system: on Wi-Fi, on power, later. The
  app asks; it doesn't command.
- **The user is told.** Android shows a transfer that is carried on, and
  the user can stop it there. iOS shows nothing. A transfer has a title
  for the one that does.
- **Downloads are interrupted.** A network drops, the user pauses. A
  download goes on from where it stopped if the server allows, and the
  app shouldn't have to know which.
- **A module of its own.** An app declares every contract of the modules
  it links. Put in `DynamicNetworking`, this would make every app that
  fetches a page declare files and transfers too, and fail to load on a
  host that has HTTP and not these.

## For a guest

```swift
import DynamicTransfers

let transfers = TransferManager.shared

// A map for offline use: left to the system, on Wi-Fi.
var options = TransferOptions(title: "Berlin map")
options.continuesInBackground = true
options.allowsExpensiveNetwork = false
let download = try await transfers.download(
    TransferRequest(url: "https://example.com/maps/berlin.tiles"),
    to: .documents / "maps/berlin.tiles",
    options: options)

// While the app is open, a view follows it.
ProgressView(value: download.fractionCompleted ?? 0)
Button("Pause") { download.pause() }

// It ends once, with the server's answer or an error.
let response = try await download.finished()

// When the app next starts: what was carried on meanwhile.
for transfer in try await transfers.all() where transfer.state == .completed {
    show(transfer.file)
    transfer.remove()
}
```

### Starting

| | |
|---|---|
| `download(_:to:options:)` | from a URL to a file. The file is as `Files` names it |
| `upload(file:with:options:)` | a file's bytes as the request's body |
| `TransferRequest(url:method:headers:)` | `GET` for a download and `POST` for an upload unless it says |

Both answer with a `Transfer` once the host has taken it on, which is
before any byte moves. A request the host refuses fails there: a URL that
isn't `http` or `https`, a file the app can't write, a transfer the
manifest's `.network` doesn't cover.

`TransferOptions`:

| | |
|---|---|
| `title` | what the system shows for it, where it shows anything |
| `continuesInBackground` | left to the system, to carry on after the app is closed. `false` unless set |
| `allowsExpensiveNetwork` | whether it may use mobile data. `true` unless set |
| `isDiscretionary` | the system may wait for a good moment: power, Wi-Fi, the night. `false` unless set |
| `completionMessage` | if set, a notification with this text when a transfer that was carried on finishes with the app closed. It needs the app's leave to notify |

### A transfer

| | |
|---|---|
| `id` | the host's, the same at every launch |
| `kind` | `.download` or `.upload` |
| `request`, `file`, `options` | as it was started |
| `state` | observable: `.waiting`, `.running`, `.paused`, `.completed`, `.failed`, `.cancelled` |
| `bytesTransferred`, `bytesExpected`, `fractionCompleted` | observable. The last two are nil until the size is known |
| `response` | the status, the content type and the suggested file name, once there is one |
| `error` | why it failed |
| `pause()`, `resume()` | |
| `cancel()` | stops it and discards what it had |
| `remove()` | forgets a transfer that has ended |
| `finished()` | waits for the end: the response, or a `TransferError` |

- **`.waiting`** is taken on and not moving: for a network, for its
  turn, for the system's good moment.
- **A paused download keeps what it has.** `resume()` goes on from there
  if the server answers a range request for the same content, and
  starts again if it doesn't. The app sees `bytesTransferred` go back.
- **An upload can't be resumed.** Pausing one stops it; resuming starts
  it again.
- **Ended transfers stay in the list** until the app removes them, so
  that it can't miss one that finished while it was closed. The host
  drops them after thirty days.

### What a download leaves

**The file is whole or it isn't there.** A download is written beside
its destination, or in the host's own space, and moved into place when
the last byte is in and the server said yes. A file already there is
replaced at that moment and not before. A failed or cancelled download
leaves nothing at the destination.

**Only a success is a file.** A response outside 200 to 299 fails the
transfer with `.httpStatus`, and `response` has the status. An error
page is never saved as the map.

### After the app has gone

`transfers.all()` lists every transfer the host has: those still moving
and those that ended. A transfer started without
`continuesInBackground` and cut short by the app closing is `.paused`,
with what it had.

`transfers.onChange` and `transfers.changes` say when any transfer
changes, for a list that shows them all.

The guest isn't started when a transfer ends. The host tells the user,
if `completionMessage` asked it to, and the app learns when it next
runs.

### Errors

`TransferError`: `.cancelled`, `.invalidRequest`, `.fileNotFound`
(an upload's file), `.fileNotWritable`, `.outOfSpace`, `.network` with
the `NetworkError` it was, `.httpStatus`, `.authenticationRequired`,
`.notAllowedInBackground`, `.unavailable`, and `.unknown` for a code
from a newer host.

## The contract

```swift
@DynamicRuntime("org.pureswift.transfers.Transfers", requires: .network)
public protocol Transfers: AnyObject {

    static func shared() -> Self

    /// `kind`: 1 download, 2 upload. `headers`: names and values in turn.
    /// A file as `Files` names it. `options`: `TransferOptions` bits.
    /// Answered by `didStart`, with the transfer's record.
    func start(_ kind: Int32, url: String, method: String, headers: [String],
               directory: Int32, path: String,
               title: String, completionMessage: String, options: Int32,
               callback: TransferCallback)

    /// Every transfer the host has, oldest first. Answered by `didList`.
    func list(_ callback: TransferCallback)

    func pause(_ identifier: String)
    func resume(_ identifier: String)
    func cancel(_ identifier: String)

    /// Forgets a transfer that has ended. One still moving is left.
    func remove(_ identifier: String)

    /// Told when a transfer changes. Nil stops it.
    func setDelegate(_ delegate: TransfersDelegate?)
}

@DynamicCallback("org.pureswift.transfers.TransferCallback")
public protocol TransferCallback: AnyObject {
    func didStart(_ record: [String])
    /// Records one after another, each `Transfers.recordLength` long.
    func didList(_ records: [String])
    /// A `TransferError` raw value.
    func didFail(_ error: Int32, message: String)
}

@DynamicCallback("org.pureswift.transfers.TransfersDelegate")
public protocol TransfersDelegate: AnyObject {
    func didChange(_ record: [String])
    func didRemove(_ identifier: String)
}
```

A record is sixteen strings: the identifier, the kind, the state, the
URL, the method, the directory, the path, the title, the options, the
bytes moved, the bytes expected (empty if unknown), the status (empty
before a response), the content type, the suggested file name, the
error, and the network error behind it. Numbers are decimal. A fetch of
photos and a calendar's fields cross the same way.

### Rules every host follows

- **One answer for each call,** on the main thread, and the delegate on
  the main thread too.
- **`didStart` comes before any `didChange`** for that transfer.
- **Progress is told at most four times a second** for a transfer, and
  every change of state at once.
- **A transfer ends once.** After `.completed`, `.failed` or
  `.cancelled` it never changes again.
- **The file is whole or absent,** as above. So is the rule that only a
  success is a file.
- **Redirects are followed,** up to the platform's limit.
- **A challenge fails the transfer** with `.authenticationRequired`.
  There may be nobody to ask. An app that needs to sign in puts the
  header in its request.
- **The request is kept as secret as the platform can.** For a transfer
  that is carried on, the host stores the headers to send them later.
- **A destination in the app's own directories** for a transfer that is
  carried on: documents, data or caches. A file the user picked is the
  app's to reach only while it runs; such a transfer fails with
  `.notAllowedInBackground`. A transfer that isn't carried on can write
  wherever `Files` can.
- **A transfer that can't be carried on is refused, not run in front.**
  A host with nothing to carry it fails the start with
  `.notAllowedInBackground`, so the app can run it without the option
  and say so.
- **Pause keeps a download's bytes; cancel discards them.**
- **Identifiers are the host's,** never used twice, and good at every
  launch until the transfer is removed.

## The shared host

`RuntimeTransfers`, for hosts written in Swift:

- **`HostTransfers`** keeps the rules: the records and their thirty
  days, written to a file in the host's space so they are there at the
  next launch; identifiers; the rate of progress; whole or absent; the
  destination checked against `HostFiles`; the states.
- **`TransferEngine`** is what a platform supplies: start this record,
  pause it, resume it, cancel it, and say what it's doing. An engine
  reports to `HostTransfers`, as a camera's does.
- **`URLSessionTransferEngine`** runs transfers in the host's process
  over `URLSession`, on Apple platforms and Linux: a download written to
  a part file, resumed with `Range` and `If-Range`. It carries nothing
  on by itself.
- **`MemoryTransferEngine`**, for tests: a server the test scripts, byte
  by byte.
- **A platform that can carry transfers on** hands the engine a second
  one for them. The Darwin host's is a background `URLSession`.

## Capability and the manifest

`.network`, as `HTTPSession` has. The manifest gains nothing.

A platform that has to declare a transfer service declares it when the
app's contracts include `Transfers`, which the packager can see. Android
needs a foreground service of the data-sync kind for uploads and for
downloads `DownloadManager` won't take.

`completionMessage` uses the app's `.notifications`. Without the
capability, or without the user's leave, nothing is shown.

## Per host

From each platform's documentation. None of it has been tried.

| Host | In front | Carried on |
|---|---|---|
| iOS / macOS | `URLSession` in the app | A background `URLSession`: download tasks, and upload tasks from a file. The system relaunches the app in the background when they end; the host handles that itself and starts no guest. The system cancels them if the user force-quits the app. `isDiscretionary` and `allowsExpensiveNetworkAccess` map across. A paused download is its resume data |
| Android | OkHttp to a file, with `Range` to resume | A user-initiated data transfer job from Android 14, a foreground service before; each with a notification that has the title and a way to stop. `DownloadManager` for a plain `GET` to shared storage. They survive a restart of the device |
| Linux | The shared engine | A transfer service in the host, which isn't written: until it is, starts with the option fail with `.notAllowedInBackground` |
| Browser | `fetch`, streamed into the origin's private files | Background Fetch, in the browsers that have it; elsewhere refused |

## Not in this design

- **A web page's downloads.** A link the user taps in a `WebView` is the
  browser engine's to fetch, with its cookies. That is in `WebKit.md`'s
  list.
- **Starting the guest when a transfer ends.** `BackgroundTasks.md` has
  the way to start a guest with no window; joining the two can follow.
- **A body made as it's sent.** An upload's body is a file. An app that
  builds a multipart form writes it to a file first.
- **An upload's reply.** The status and the headers named above are
  kept; the body the server answers with isn't.
- **A destination the user picked, for a transfer that is carried on.**
  It would need the grant kept alive without the app.
- **Certificate pinning, and client certificates.**
- **Sockets, and anything that isn't HTTP.**

## Alternatives weighed

- **`downloadTask` and a background configuration on `HTTPSession`,** as
  `URLSession` has them. Three things stood against it. A task's
  delegate is an object in the guest, which a transfer has to outlive.
  The Darwin and Android hosts implement `HTTPSession` themselves, so
  each new method there needs a default that can do nothing useful. And
  naming a file in `DynamicNetworking` would make every app that uses
  HTTP declare `Files`.
- **Two contracts,** one for file tasks while the app runs and one for
  what's carried on. They differ by one option. An app that starts a
  download in front and then wants it carried on would have to start it
  again.
- **Android's `DownloadManager` as the model.** It takes `GET` alone,
  few headers, and no uploads.
- **Leaving it to the guest,** as today. See the top of this page.

## Example and tests

Planned:

- **`examples/ExampleTransfers`**: a list of downloads. Start one, watch
  it, pause and resume it, cancel one, and find at the next launch one
  that finished while the app was closed. Run as `App.wasm`, as a sealed
  slice and through wasm2c, with a server the test scripts.
- **`DynamicTransfersTests`**: the contract's names and signatures;
  records to values and back; a transfer's state followed by a view;
  `finished()` for each ending; a newer host's values.
- **`RuntimeTransfersTests`**, on macOS and Linux: each rule above over
  `MemoryTransferEngine`; and `URLSessionTransferEngine` against a
  `URLProtocol` that answers without a network: a whole file, a resumed
  one, a server that ignores ranges, a changed file under the same URL,
  an error status, a full disk, records read back at the next launch.

## Questions for review

1. **Is one contract with an option right,** or should what's carried on
   be its own?
2. **`completionMessage`:** the host posting the notification itself, so
   that no guest need start. The alternative is nothing until the app
   can be woken.
3. **Thirty days** for an ended transfer nobody removed.
4. **The module's name:** `DynamicTransfers`.
