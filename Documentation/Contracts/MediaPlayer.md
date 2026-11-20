# Media players

**Status:** implemented in this repository: the guest side, and the part of
the host side every host written in Swift shares, with
[NowPlaying](NowPlaying.md)'s additions. No platform host has players yet,
so nothing has been decoded or heard; each needs an engine ([The shared
host](#the-shared-host)).

Module `DynamicMedia`: playing a song, a podcast or a video, from the
bundle, the app's files or the network. The host decodes, keeps time and
shows the picture; the guest says what to play and follows along.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `MediaPlayback` | contract, `requires: .audio` | `AVPlayer`, shown by AVKit | Media3's `ExoPlayer`, shown by its `PlayerView` | a GStreamer `playbin`, its frames in a texture Cacao composites | a `<video>` or `<audio>` element |
| `MediaPlaybackDelegate` | callback | key-value and time observers | `Player.Listener` | bus messages | the element's events |

Guest-side Swift, named as Apple's frameworks name them without the `AV`:

- **`MediaPlayer`**: the observable player app code uses. `AVPlayer`'s
  place.
- **`VideoPlayer`**: the SwiftUI view that shows one, as AVKit's is.
- **`AudioPlayer`**: a player for one sound, with `AVAudioPlayer`'s
  properties and methods.
- `MediaSource`, `MediaError`, `VideoScaling`, `VideoControls`.

One contract serves all three: every platform's player plays both sound
and pictures, so an `AudioPlayer` is a `MediaPlayer` that's never shown.

The render IR gains one node, `VideoPlayer`, whose `player` prop is the
host player's `identifier()`, as `WebView`'s `page` is.

## What shapes it

- **Media is the host's, start to finish.** Decoding, the audio clock,
  syncing sound to picture and showing frames all happen in the host, on
  its own threads. No sample and no frame crosses to the guest.
- **It isn't the game audio contract.** [`DynamicAudio`](Audio.md) mixes
  short sounds with low latency and takes generated PCM. This plays long
  things, one per player, that may come over the network, may have
  pictures, and are sought and paused by the user. An app can use both.
- **Loading is never instant.** A file's duration isn't known in a
  browser until its header arrives, and a stream's never is. So nothing
  about a source is answered by a return value: it arrives when the host
  knows.
- **Time isn't polled.** The host says where playback is, when it was
  there, and how fast it's going. The guest works out the position at any
  moment from that, without a call.
- **A player is separate from where it's shown**, as a web page is. It
  loads and plays on screen or not, and keeps its place while its view
  comes and goes.

## For a guest

### Video

```swift
import SwiftUI
import DynamicMedia

struct TrailerView: View {

    let player: MediaPlayer

    var body: some View {
        VStack {
            VideoPlayer(player)
                .frame(height: 220)
            if player.isBuffering {
                ProgressView()
            }
            Button(player.isPlaying ? "Pause" : "Play") {
                player.isPlaying ? player.pause() : player.play()
            }
        }
    }
}

let player = MediaPlayer()
player.load(.url("https://example.com/trailer.mp4"))
player.play()
```

To only show a URL, `VideoPlayer(url: "https://example.com/trailer.mp4")`
keeps a player of its own.

- **Sources.** `MediaSource` is one of:
  - `.url(_:)`: `http` or `https`. Needs `.network` in the manifest.
  - `.file(_:)`: a `FilePath`, as [Files](Files.md) has them. `.resource(_:)`
    is one in the bundle.
  - `.data(_:type:)`: a whole file's bytes and its MIME type, for a sound
    the app made or already has in memory.
- **A player has one source at a time.** `load` replaces it. To play a
  list, load the next in `onEnd`.
- **`VideoPlayer` takes the space it's offered** and fits the picture
  inside it. `VideoPlayer(player, scaling: .fill)` crops to fill, and
  `.stretch` distorts. `player.videoSize` is the picture's own size, once
  it's known.
- **Controls.** `VideoPlayer(player)` shows the platform's own: play,
  pause, a scrubber, full screen where it has one. What the user does
  with them arrives as the same changes to the player. `controls: .none`
  shows only the picture, for an app that draws its own from the
  player's properties.
- **Without a view a player still plays its sound.**

### The player

`MediaPlayer` is observable: a view that reads a property is updated when
it changes.

| Property | |
|---|---|
| `status` | `.empty`, `.loading`, `.ready` or `.failed` |
| `isPlaying` | sound or picture is advancing |
| `isBuffering` | it would be playing, and is waiting for data |
| `pauseReason` | why it isn't playing: the app asked, the user did, the system interrupted, it ended, it wasn't allowed |
| `currentTime` | seconds; set it to seek |
| `duration` | seconds; `nil` until known, and for a live stream |
| `bufferedTime` | how far past `currentTime` is loaded |
| `videoSize` | the picture's size in pixels; zero for sound alone |
| `hasVideo`, `hasAudio` | |
| `rate` | 0.5...2, pitch kept. 1 by default |
| `volume`, `isMuted` | 0...1 |
| `isLooping` | starts again at the end |
| `error` | a `MediaError`, when `status` is `.failed` |

| Method | |
|---|---|
| `load(_:)` | start loading a source, paused at its start |
| `play()`, `pause()` | |
| `seek(to:) async` | returns when playback is there; `false` if another seek replaced it |
| `unload()` | let go of the source |
| `onEnd`, `onFailure` | called when playback reaches the end and isn't looping, and when it fails |
| `events`, `times(every:)` | streams of what happens, and of the time (below) |
| `MediaPlayer.canPlay(_:)` | whether this host plays a MIME type: `.no`, `.maybe`, `.probably` |

- **`play()` before `.ready` is remembered.** Playback starts when it can.
- **`currentTime` is exact when read.** It's computed from the host's
  last report and the clock, so a progress bar that reads it each frame
  moves smoothly.
- **It changes, for views, a few times a second:** every
  `timeUpdateInterval` (half a second by default) while playing, and at
  every seek, pause and resume. A property that changed sixty times a
  second would redraw every view that read it sixty times a second.
- **Releasing the `MediaPlayer` stops it** and frees the host's player.

### Following a player

Apple's players are followed with key-value observing, notifications and
time observers. None of those exist here. There are three ways instead,
each for a different reader:

| To | Use | In Apple's API |
|---|---|---|
| show state in a view | read the property | KVO on `status`, `timeControlStatus`, `rate` |
| react to what happens, in code | `for await event in player.events` | KVO, and `AVPlayerItem`'s notifications |
| do something at regular times | `for await time in player.times(every: 0.1)` | `addPeriodicTimeObserver` |
| handle one thing simply | `onEnd`, `onFailure` | a notification observer |

- **Properties are for views.** `MediaPlayer` is observable, so a view
  that reads `player.isPlaying` is evaluated again when it changes, with
  nothing to subscribe to or remove.
  `withObservationTracking` does the same for code outside a view, once
  per call, as Apple's does.
- **`events` is for logic:** a playlist, analytics, a state machine. It's
  an `EventStream<MediaEvent, Never>`, an `AsyncSequence`:

  ```swift
  for await event in player.events {
      switch event {
      case .loaded(let duration, let videoSize): …
      case .playing: …
      case .paused(let reason): …        // MediaPauseReason
      case .buffering: …
      case .seeked(let time): …
      case .ended: playNext()
      case .failed(let error): …
      }
  }
  ```

  - A stream gets what happens after it's first awaited. It doesn't
    replay; read the properties for where things stand.
  - Any number can run at once, and each gets every event.
  - It ends when the player is released, and when its task is cancelled.
  - Events arrive on the main thread, in the order they happened, after
    the properties have changed.
- **`times(every:)` is for ticks:** an `EventStream<Double, Never>` of
  `currentTime`, at the interval while playing and once at each seek. It
  needs nothing more from the host, since the guest already knows the
  position. For a view, read `currentTime` and let it update.
- **The closures** are for when one handler is enough. `onEnd` and
  `onFailure` are called before the stream's event.
- **There's no delegate on `MediaPlayer`.** One delegate means one
  listener, and `AVPlayer` has none either. `AudioPlayer` has one because
  `AVAudioPlayer` does, and it has `events` too.

### Audio

```swift
let player = AudioPlayer(.resource("music/theme.mp3"))
player.numberOfLoops = -1
player.volume = 0.8
player.play()
```

`AudioPlayer` has `AVAudioPlayer`'s surface, so code written for it ports
by dropping the prefix:

| | |
|---|---|
| Methods | `prepareToPlay()`, `play()`, `pause()`, `stop()` |
| Properties | `isPlaying`, `currentTime` (settable), `duration`, `volume`, `rate`, `numberOfLoops` (−1 for ever) |
| Delegate | `audioPlayerDidFinishPlaying(_:successfully:)`, `audioPlayerDecodeErrorDidOccur(_:error:)` |

Where it differs:

- **Making one never throws, and `duration` starts at 0.** Whether a file
  can be played isn't known until it's loaded, which a browser does
  asynchronously. `isReady` says when, and an unplayable file calls
  `audioPlayerDecodeErrorDidOccur`.
- **It takes a URL too.** `AVAudioPlayer` plays only local files; this is
  the same player underneath as `MediaPlayer`.
- **No `pan`, metering or `play(atTime:)`.** A sound that needs placing or
  exact timing is [`DynamicAudio`](Audio.md)'s.
- It's observable like `MediaPlayer`, and `player.mediaPlayer` is the one
  underneath.

## Formats

Every host plays these. A host may play more; `MediaPlayer.canPlay(_:)`
says, and an app that relies on more isn't portable.

| | Container | Codec |
|---|---|---|
| Video | MP4 (`.mp4`, `.m4v`, `.mov`) | H.264, to High profile at 1080p, with AAC-LC sound |
| Audio | MP3 | |
| Audio | MP4 (`.m4a`) | AAC-LC |
| Audio | WAV | PCM, 8- or 16-bit |

- **HTTP Live Streaming isn't in that list.** Apple platforms and Android
  play it, GStreamer does, and most browsers need a script to. Ask
  `canPlay("application/vnd.apple.mpegurl")`.
- **WebM, VP9, AV1, Opus and Ogg aren't either.** Apple's players don't
  play WebM.
- **H.264 on the Linux distro is the distro's to ship**: a decoder, in
  software or the hardware's. It's what makes this contract cost
  something there.
- **No protected content.** There's no FairPlay or Widevine here.

## The contract

```swift
@DynamicRuntime("org.pureswift.media.Playback", requires: .audio)
public protocol MediaPlayback: AnyObject {

    static func make(_ delegate: MediaPlaybackDelegate) -> Self

    /// 0 no, 1 maybe, 2 probably.
    static func canPlay(_ mimeType: String) -> Int32

    /// What a `VideoPlayer` node carries to say which player it shows.
    func identifier() -> Int32

    // One source at a time. Each replaces the last, and is answered by
    // `didLoad` or `didFail`.
    func loadURL(_ url: String)
    func loadFile(_ directory: Int32, path: String)       // FileDirectory
    func loadData(_ data: [UInt8], mimeType: String)
    func unload()

    func play()
    func pause()

    /// Answered by `didSeek` with the same `request`.
    func seek(_ position: Double, request: Int32)

    func setRate(_ rate: Float)
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
    func setLooping(_ looping: Bool)

    /// How often `didChangeTime` is sent while playing.
    func setTimeUpdateInterval(_ seconds: Double)
}

@DynamicCallback("org.pureswift.media.PlaybackDelegate")
public protocol MediaPlaybackDelegate: AnyObject {

    /// The source can be played. `duration` is negative when it isn't
    /// known, as for a live stream. Sizes are the picture's pixels.
    func didLoad(duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool)

    /// `MediaState`, and for a pause its `MediaPauseReason`.
    func didChangeState(_ state: Int32, reason: Int32)

    /// Playback was at `position` seconds at `timestamp`, nanoseconds on
    /// the `Clock.now()` timeline, advancing at `rate` (0 when it isn't).
    func didChangeTime(position: Double, timestamp: Int64, rate: Float)

    /// Seconds loaded past the current position.
    func didChangeBuffer(_ seconds: Double)

    func didSeek(_ request: Int32, finished: Bool)

    /// Reached the end, and isn't looping.
    func didEnd()

    func didFail(_ code: Int32, message: String)
}
```

| `MediaState` | |
|---|---|
| 0 `empty` | no source |
| 1 `loading` | a source, not yet playable |
| 2 `paused` | |
| 3 `playing` | |
| 4 `buffering` | asked to play, waiting for data |
| 5 `failed` | |

| `MediaPauseReason` | |
|---|---|
| 0 `requested` | the guest called `pause()`, or never called `play()` |
| 1 `user` | the platform's controls, a headset button |
| 2 `interrupted` | a call, or another app took the sound |
| 3 `background` | the app left the foreground |
| 4 `ended` | |
| 5 `notAllowed` | the platform refused to start (below) |
| 6 `routeChanged` | headphones were unplugged |

| `MediaError.Code` | |
|---|---|
| 1 `notFound` | no such file, or the server said so |
| 2 `unsupportedFormat` | |
| 3 `network` | the connection failed or was lost |
| 4 `notPermitted` | a URL without `.network`, or a scheme that isn't `http` or `https` |
| 5 `decoding` | the data is damaged |
| 6 `unavailable` | no output device, or no capability |
| 0 `unknown` | |

## What the platforms make the contract say

**Browsers don't start by themselves.** A media element plays only inside
a user's action (a tap, a key), unless it's muted. Elsewhere `play()`
leaves the player paused with reason `notAllowed`. Call `play()` from a
button's action, or mute a video that starts itself.

**Interruptions.** A call or another app can take the sound. The host
pauses, reports `interrupted`, and plays again when the system says it
may. If the system doesn't, the player stays paused.

**It plays as media, not as a game.** A player with sound silences other
apps' sound and ignores the ring/silent switch on iOS, as a music or
video app does. A muted player, and one whose source has no sound, takes
nothing from anyone. `DynamicAudio`'s output has its own setting for
mixing with others; when an app uses both, a playing media player wins.

**In front, unless it asks.** When the app leaves the foreground the host
pauses every player, with reason `background`, and doesn't resume them. A
player with `playsInBackground` plays on, where the manifest allows:
[NowPlaying](NowPlaying.md).

**Unplugging headphones pauses**, as the platforms expect of media.

**Seeking lands on what can be shown.** The host seeks to the exact time
where the format lets it, and to the nearest earlier frame where it
doesn't. `didChangeTime` says where it ended up.

**A network source streams.** The host fetches what it needs as it
plays. To play offline, download with [HTTPClient](HTTPClient.md) into a
[file](Files.md) and load that.

**The Linux sandbox.** `.audio` is what binds the sound server into the
sandbox (`DynamicRuntime.md` §7.3). The sandbox's `/dev` holds only the
devices a capability names (§7.8), and the design doesn't yet say which
capability a hardware decoder's device belongs to. Until it does, a host
there decodes in software.

## For a host

1. `make(_:)`: create the platform's player, with nothing loaded, and
   keep the delegate.
2. On a load, report `loading`, then `didLoad` and `paused`, or `didFail`
   and `failed`. Fetch only enough to know what the source is and to
   start playing quickly.
3. When a `VideoPlayer` node appears whose `player` prop equals a
   player's `identifier()`, show that player's picture there, with the
   controls and scaling the node's props ask for. When the node goes,
   keep the player: it's still loaded, and may be playing.
4. Report every change through the delegate, on the main thread,
   whoever caused it: the guest, the user with the platform's controls,
   or the system.
5. Send `didChangeTime` at the interval while playing, and at once when
   playback starts, stops, seeks, changes rate or loops.
6. Destroy the platform's player when the guest releases the
   `MediaPlayback`.

- **Decoding and presenting stay off the main thread** and never wait
  for the guest. A guest that's busy delays only what it's told, not
  what's heard.
- **`loadData`** is a file in memory: the host may write it to a
  temporary file, or feed its player from the bytes.
- **`loadFile` takes the same directories as `Files`**, bundle included,
  and refuses a path that contract would.

## Threading

Every delegate method runs on the main thread (§6.4). The host's decoder,
audio and display threads touch only the host's player.

## Not in this design

- **Background playback, and what's playing on the lock screen,** which
  were left out of this design and are [NowPlaying](NowPlaying.md)'s.
- **Picture in picture** and playing to another device (AirPlay, Cast),
  beyond what the platform's own controls offer.
- **Playlists and gapless playback.** One source at a time.
- **Choosing tracks:** subtitles, captions and alternative audio. The
  platform's controls show what the file has, where they can.
- **Request headers and cookies** for a URL. A browser can't set them on
  a media element.
- **A frame as an image**, for a thumbnail or to draw with. It would
  give a [Drawing](Drawing.md) `Image`.
- **Recording**, and levels for a meter.
- **Protected content.**

## The shared host

A host written in Swift implements `MediaPlatform` and `MediaEngine`, in
`RuntimeMedia`, and `HostMediaPlayback` does the rest:

```swift
final class MyPlayers: MediaPlatform {
    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine { … }
    func canPlay(_ mimeType: String) -> MediaSupport { … }
    func showNowPlaying(_ nowPlaying: HostNowPlaying?) { … }       // optional
}

final class MyEngine: MediaEngine {
    func load(_ source: HostMediaSource) { … }      // .url, .file(path:), .data
    func unload(); func play(); func pause()
    func seek(to position: Double, completion: @escaping (Bool) -> Void)
    var currentTime: Double { get }
    func setRate(_:); func setVolume(_:); func setMuted(_:); func setLooping(_:)
    func setTimeUpdateInterval(_:)
}

HostMediaPlayback.platform = MyPlayers()
HostMediaPlayback.clock = runtime.clock
HostMediaPlayback.allowsNetwork = declared.contains(.network)
HostMediaPlayback.allowsBackground = audioOptions["background"] == "true"
HostMediaModule.register(in: runtime)
```

An engine reports to the `HostMediaPlayback` it was made for: `loaded`,
`stateChanged`, `timeChanged`, `bufferChanged`, `ended`, `failed`.

- **It checks and finds each source** before an engine sees it: a URL's
  scheme and the manifest's `.network`; a file through
  `HostFiles.path(of:path:)`, so the bundle, the app's files and a picked
  document are all files, and one that isn't there never reaches the
  engine.
- **It remembers a `play()` that came too early,** and plays when the
  source has loaded.
- **It answers each seek once,** and `false` to one that another replaced.
- **It stamps each time report** with the guest's clock.
- **It says a pause once,** with the reason: the guest's, the user's, the
  background, an interruption, unplugged headphones.
- **`HostMediaPlayback.player(for:)`** finds the player a `VideoPlayer`
  node names, and its `engine` is what the host shows there.

Android and the browser aren't written in Swift, and implement the
contract themselves.

## Example and tests

`examples/ExampleMedia`: a small music player. It plays the songs in its
bundle one after another, says what's playing, answers next and previous,
plays on in the background, and shows a second player's picture.

- `DynamicMediaTests`: the contract's keys and signatures, and
  `MediaPlayer`, `VideoPlayer` and `AudioPlayer` against a scripted host.
- `RuntimeMediaTests`: `HostMediaPlayback` over players the test keeps in
  memory, with real files, driven from the guest.
- The example runs against `HostMediaPlayback` as `App.wasm` under WasmKit
  (`Packages/RuntimeWasm`), and as a sealed native slice and wasm2c output
  (`Packages/LinkedSlice`).

Everything is tested against an engine in memory. No file has been
decoded and no sound played: the formats, the platforms' behaviour and
the timing above are from each platform's documentation.

## Decided in review

The design's proposals were taken as they stood:

- **Names:** `MediaPlayer`, `VideoPlayer`, `AudioPlayer`.
- **One contract for both** sound and pictures.
- **The module is `DynamicMedia`,** imported by that name.
- **The platform's controls by default** in `VideoPlayer`.
- **The formats every host must play:** H.264 and AAC in MP4, MP3 and
  WAV.
- **`requires: .audio`** for every player. The manifest has the
  capability now.
- **Background playback is in the first version:**
  [NowPlaying](NowPlaying.md).

What was built differs in small ways:

- `MediaPlayer.canPlay(_:)` gives a `MediaSupport`: `.no`, `.maybe` or
  `.probably`.
- `MediaEvent.loaded` carries the duration and a `MediaSize`, and there
  are `.nextTrack` and `.previousTrack`.
- `AudioPlayer` holds its delegate strongly, since Embedded Swift has no
  weak references. Set it to `nil` to let it go.
