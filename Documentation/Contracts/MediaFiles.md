# What's in a media file: tags, artwork and tracks

**Status:** a draft, not reviewed. Nothing in this document is built.

Two things the [media player](MediaPlayer.md) design left out, which the
music and video players need (`PlannedApps.md`):

- **A file's tags and artwork, without playing it.** A music library
  shows hundreds of songs by title, artist and album, with their covers.
  Today an app learns a song's duration only by loading it into a player,
  and its title not at all.
- **Choosing tracks:** a video's subtitles, and its other languages. The
  platform's controls show what a file has where they can, and the app
  can neither offer the choice nor remember it.

Both are in module `DynamicMedia`. Tags are a new contract, served by the
shared media host. Tracks are additions to `MediaPlayback`.

| | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|
| Tags and artwork | `AVURLAsset`'s `commonMetadata` and `duration` | `MediaMetadataRetriever`, `getEmbeddedPicture()` | GStreamer's `GstDiscoverer`, its tag list | none: a script would parse ID3 and MP4 boxes |
| Tracks | `AVMediaSelectionGroup`s, `.audible` and `.legible` | Media3's `Tracks`, and `TrackSelectionParameters` overrides | `playbin`'s `n-audio`, `n-text`, `current-audio`, `current-text` | `textTracks`; `audioTracks` in Safari only |

These names are from what's known of each platform, and haven't been
checked against its documentation yet. The Linux host has no media host
yet; the browser has none.

## What shapes it

- **Tags are read by the host, as files are played by it.** The formats
  are many (ID3 versions 1 to 2.4, MP4 atoms, Vorbis comments, FLAC
  blocks), every platform reads them, and a guest parser would be a
  library of its own. The host also reads a picked document the guest
  can't open itself.
- **One read is one call,** answered later through a callback that's
  called once, as a picker's is (`Documents.md`). A platform reads a file
  in tens of milliseconds, and a library scans thousands, so the host reads
  off the main thread and the guest keeps a few reads going at a time.
- **Tags travel as strings,** key then value, in one array. New keys need
  no new method, and a guest ignores keys it doesn't know. Numbers are
  decimal text.
- **Artwork only when asked,** as the image file's bytes. A cover can be a
  megabyte, and a list of songs doesn't need them all at once.
- **A new contract, in the shared host.** Tags aren't a player's: a
  library reads them without making one. `HostMediaModule` registers it,
  so every host that uses the shared media host has it, answering
  `unavailable` until its platform reads tags.
- **Tracks are the player's,** and its delegate says what the loaded file
  has and which are chosen, whoever chose them: the app, or the user in
  the platform's controls.

## For a guest

```swift
import DynamicMedia

// One song.
let tags = try await MediaTags.read(from: .documents / "Music/so-what.mp3")
tags.title          // "So What"
tags.artist         // "Miles Davis"
tags.album          // "Kind of Blue"
tags.trackNumber    // 1
tags.duration       // 562.0

// A song from a folder the user picked, with its cover.
let song = try await MediaTags.read(from: document.path, artwork: true)
if case .data(let bytes, let type)? = song.artwork {
    cover = Image(data: bytes)   // DynamicDrawing
}

// A whole library: as many reads as the host does well at once.
for file in files {
    library.append(try await MediaTags.read(from: file))
}

// A video's tracks.
player.load(.file(.documents / "Films/heist.mp4"))
// Once it's loaded:
player.subtitleTracks      // [MediaTrack(name: "English", language: "en"), MediaTrack(name: "Français", language: "fr")]
player.selectedSubtitleTrack = player.subtitleTracks.first { $0.language == "fr" }
player.selectedSubtitleTrack = nil   // subtitles off
player.selectedAudioTrack = player.audioTracks.last
```

### Tags

- **`MediaTags.read(from:artwork:)`** reads a `FilePath`: the bundle, the
  app's directories, or a document. It throws `MediaError`: `notFound`,
  `notPermitted` for a document the app no longer holds,
  `unsupportedFormat` for a file that isn't media, and `unavailable` on a
  host that can't read tags. A completion-handler form takes the same
  arguments.
- **A tag the file doesn't have is `nil`,** and a file with none still
  reads: everything is `nil` but the duration, which the host takes from
  the stream.
- **The properties:** `title`, `artist`, `album`, `albumArtist`,
  `composer`, `genre`, `year`, `trackNumber`, `trackCount`, `discNumber`,
  `discCount`, `isCompilation`, `duration` (seconds), and `artwork`
  (`NowPlayingArtwork`, `.data`, so it goes straight to `nowPlaying`).
  Every tag the host read is also in `values`, by its key, for one the
  type doesn't name.
- **Reads are queued in the guest,** four at a time, in the order asked.
  A read the app stops waiting for, by cancelling its task, is dropped
  from the queue if it hasn't started, and its answer is let go if it
  has.
- **A URL isn't read.** Tags of a stream come with it, and a remote file
  would be fetched whole on some platforms.

### Tracks

- **`audioTracks` and `subtitleTracks`** are the loaded file's, each a
  `MediaTrack` with a `name` the platform gives (often the language's
  name) and a `language` (a BCP 47 tag, `nil` when the file doesn't say).
  Empty before a file is loaded, and for a file with one audio track and
  no subtitles.
- **`selectedAudioTrack` and `selectedSubtitleTrack`** are observable and
  settable. `nil` for subtitles is off; for audio it's the file's default.
  A choice made in the platform's controls changes them too.
- **Subtitles are drawn by the host,** over the picture, as the platform
  draws them, with the user's caption settings where the platform has
  them.
- **A choice lasts for the file.** Loading another resets both to the
  file's defaults; an app that remembers a language chooses again once
  `status` is `.ready`.

## The contracts

```swift
/// A file's tags, read by the host.
@DynamicRuntime("org.pureswift.media.Metadata")
public protocol MediaMetadata: AnyObject {

    static func shared() -> Self

    /// Reads the file `Files` names by `directory` and `path`. Answers
    /// `callback` once, on the main thread.
    func read(_ directory: Int32, path: String, artwork: Bool, callback: MediaMetadataCallback)
}

@DynamicCallback("org.pureswift.media.MetadataCallback")
public protocol MediaMetadataCallback: AnyObject {

    /// `tags`: a key, then its value, then the next key. `artwork` is an
    /// image file's bytes, empty without one or when it wasn't asked for.
    func didRead(_ tags: [String], artwork: [UInt8], artworkType: String)

    /// `code` is a `MediaError.Code` raw value.
    func didFail(_ code: Int32, message: String)
}
```

The keys: `title`, `artist`, `album`, `albumArtist`, `composer`, `genre`,
`year`, `trackNumber`, `trackCount`, `discNumber`, `discCount`,
`compilation` (`1` or `0`), `duration` (seconds, decimal), and `comment`.
A host may send others, named as the platform names them.

Added to `MediaPlayback`, with defaults that do nothing:

```swift
    /// `kind`: 0 audio, 1 subtitles. `index` into what `didChangeTracks`
    /// last listed; -1 is the default for audio, and off for subtitles.
    func selectTrack(_ kind: Int32, index: Int32)
```

Added to `MediaPlaybackDelegate`:

```swift
    /// What the loaded file has, and which are chosen. After `didLoad`,
    /// and whenever the choice changes. Names and languages are in step;
    /// an empty language is none. `selected…` is an index, or -1.
    func didChangeTracks(_ audioNames: [String], audioLanguages: [String],
                         subtitleNames: [String], subtitleLanguages: [String],
                         selectedAudio: Int32, selectedSubtitle: Int32)
```

## For a host

- **Read off the main thread,** and answer on it. Read at most what's
  needed: the tags and the stream's duration, not the samples.
- **Find the file as a player's is found:** `HostMediaPlayback.findPath`,
  so a document works and a revoked one is `notPermitted`.
- **Keys the contract names** are sent as the contract names them, with
  numbers in decimal: an ID3 `TRCK` of `3/12` is `trackNumber` 3 and
  `trackCount` 12.
- **Tracks:** list them after `didLoad`, and again when the choice
  changes from the platform's controls. Leave out tracks the platform
  can't play.

### The shared host

`MediaPlatform` gains a method with a default, and `HostMediaModule`
registers the new contract over it:

```swift
/// Reads a file's tags; on any thread, answering on any thread.
/// Default: `unavailable`.
func readTags(_ path: String, artwork: Bool,
              completion: @escaping (Result<HostMediaTags, MediaError>) -> Void)
```

`HostMediaTags` is the tags as the contract names them and the artwork.
The shared host finds the path, runs the read on `HostMediaMetadata.work`
and answers on the main thread.

`MediaEngine` gains `selectTrack(_:index:)`, with a default that does
nothing, and reports `tracksChanged(audio:subtitles:selectedAudio:
selectedSubtitle:)` to its `HostMediaPlayback`.

## Tests and an example

- **`DynamicMediaTests`:** the new contract's keys, `MediaTags` from a
  test host's answers (known keys, unknown ones, missing ones, numbers
  that aren't), errors, the guest's queue of four and a cancelled read;
  tracks from the delegate, choosing them, and resetting on a new load.
- **`RuntimeMediaTests`:** the shared host finding the file, refusing a
  revoked document, the default `unavailable`, and delivering on the main
  thread; an engine's tracks reaching the delegate.
- **`ExampleMedia`** reads its songs' titles, artists and covers from
  their tags, where it had them written into its code, and gains a
  subtitle picker for its video. On the three engines, against the test's
  stand-in.

## Not in this design

- **Writing tags.**
- **Subtitles from a separate file** (`.srt`, `.vtt` beside the video).
  AVFoundation plays only those in the file or an HLS stream; it would
  need a composition the host builds.
- **Chapters,** and the lyrics in a file's tags.
- **The system's music library** (`MPMediaLibrary`, `MediaStore.Audio`):
  songs the user's other apps keep. That's a store contract of its own,
  as contacts are.
- **Tags of a remote file or a stream.**

## Questions

1. **Four reads at a time** in the guest. The host could queue instead,
   and know its platform's best number. Is a fixed number in the guest
   enough?
2. **Separate subtitle files.** A video player for files the user brings
   often meets an `.srt` beside the video. Android and GStreamer take one;
   Apple's player needs work in the host. Leave it out for now?
3. **`MediaTags` or `MediaMetadata`** for the guest's type? Apple's
   `AVMetadataItem` is per tag; `MediaTags` says what a music app reads.
