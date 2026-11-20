# Now playing, and playing in the background

**Status:** a design for review. Nothing here is implemented, and neither
is [MediaPlayer](MediaPlayer.md), which it adds to.

Three things a music or podcast app needs that the media player design
left out, and that every platform ties together:

- **Playing on** when the app leaves the front.
- **What's playing,** shown where the system shows it: the lock screen,
  the shell's media controls, a car's display.
- **The buttons there,** and on headphones and keyboards: play, pause,
  seek, next, previous.

They are additions to the `MediaPlayback` contract and to the guest's
`MediaPlayer`, in module `DynamicMedia`. There is no new contract.

| | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|
| Playing on | the `audio` background mode, with an active audio session | a media playback foreground service | the shell doesn't stop an app that's playing | a tab that's playing isn't stopped |
| What's playing | `MPNowPlayingInfoCenter` | the `MediaSession`'s metadata | MPRIS `Metadata` | `navigator.mediaSession.metadata` |
| The buttons | `MPRemoteCommandCenter` | the `MediaSession`'s commands, and media buttons | MPRIS methods | Media Session action handlers |

## What shapes it

- **The host already knows most of it.** It owns the player, so it knows
  the position, the duration, the rate and whether it's playing. The app
  says only what the host can't know: the title, the artist, the artwork,
  and what "next" means. An app never reports elapsed time, which is the
  usual thing to get wrong.
- **The host answers the buttons it can.** Play, pause and seeking act on
  the player at once, without the guest, so they work while the guest is
  busy. The app hears of them as it hears of any change to the player.
  Only next and previous reach the app, since only it knows the list.
- **It's per player.** The player the app last described is the one the
  system shows. An app has one at a time, as each platform does.
- **Playing holds the app.** By the rule in
  [BackgroundTasks](BackgroundTasks.md), an app runs in the background
  only while something holds it. A player that's playing in the
  background is such a thing. A paused one isn't for long.
- **It's declared.** iOS and Android both require an app to say in
  advance that it plays in the background.

## For a guest

```swift
let player = MediaPlayer()
player.playsInBackground = true
player.nowPlaying = NowPlayingInfo(
    title: "So What", artist: "Miles Davis", album: "Kind of Blue",
    artwork: .file(.caches / "covers/kind-of-blue.jpg"))
player.onNextTrack = { play(queue.next()) }
player.onPreviousTrack = { play(queue.previous()) }

player.load(.file(library.path / "01 So What.m4a"))
player.play()
```

### What's playing

| `NowPlayingInfo` | |
|---|---|
| `title` | the track, the episode |
| `artist`, `album` | optional |
| `artwork` | `.file(FilePath)`, in the bundle, the app's files or a document; or `.data(_:type:)`, such as a picture from the file's tags |

- **Setting it makes this the app's now-playing player.** `nil` takes it
  away; so does releasing the player or unloading its source.
- **Set it when the source changes,** with `load`. It stays through
  pauses and seeks.
- **The position, duration and rate aren't in it.** The host reports the
  player's own. A live stream shows no position.
- **Artwork is a file or bytes,** not a URL: iOS takes only an image. An
  app that has a URL downloads it first.

### The buttons

| Button | Who answers |
|---|---|
| play, pause, play/pause | the host: it plays or pauses the player |
| seek to a position | the host |
| skip back, skip forward | the host, by `skipIntervals` seconds |
| next, previous | the app: `onNextTrack`, `onPreviousTrack` |

- **A button is offered when it can be answered.** Next and previous
  appear when their closure is set. Skipping appears when
  `skipIntervals` is: `player.skipIntervals = (backward: 15, forward: 30)`.
  Seeking appears when the source can seek.
- **What the host did arrives as usual:** `isPlaying` changes, with
  `pauseReason` `.user`; `currentTime` moves. Nothing new to handle.
- **Next and previous are also events:** `.nextTrack` and
  `.previousTrack` in `player.events`.
- **Headphone and keyboard media keys are the same buttons.**

### Playing in the background

- **`playsInBackground` keeps the sound going** when the app leaves the
  front. Without it the host pauses the player then, with reason
  `.background`, as the media player design has it.
- **It needs the manifest's leave:** `.audio(background: true)`.
  `MediaPlayer.canPlayInBackground` says whether this app has it on this
  host. Without it, setting `playsInBackground` does nothing.
- **A video's picture stops; its sound goes on.** The picture is back
  when the app is.
- **The app runs while it plays.** Its closures are called, so `onEnd`
  can load the next track. Do it promptly: a player that has stopped
  holds the app only for a moment.
- **A paused app may be stopped.** After a while in the background with
  nothing playing, the system may stop the app, and what it showed as
  playing goes with it. The app is started again when the user opens it.
- **An interruption pauses,** with reason `.interrupted`: a call, an
  alarm, another app that plays. When it ends and the system says the
  app may resume, the host resumes it.

## What it adds to the contract

```swift
// MediaPlayback gains:

    /// Says what this player is playing, and makes it the app's
    /// now-playing player. An empty title takes it away.
    func setNowPlaying(_ title: String, artist: String?, album: String?)
    /// The artwork of what was last said to be playing.
    func setArtworkFile(_ directory: Int32, path: String)      // FileDirectory
    func setArtworkData(_ data: [UInt8], mimeType: String)

    /// The buttons beyond play, pause and seeking. `commands`: bits,
    /// 1 next, 2 previous, 4 skipping. The intervals are seconds.
    func setRemoteCommands(_ commands: Int32, skipBackward: Double, skipForward: Double)

    /// Goes on playing when the app leaves the front. Ignored without
    /// the manifest's leave.
    func setPlaysInBackground(_ enabled: Bool)

    /// Whether this app may play in the background on this host.
    static func canPlayInBackground() -> Bool

// MediaPlaybackDelegate gains:

    /// A button the host can't answer: 1 next, 2 previous.
    func didReceiveCommand(_ command: Int32)
```

### Rules every host follows

- **One now-playing player per app:** the one last described. Describing
  another replaces it.
- **The host reports position, duration, rate and state itself,** from
  the player, whenever they change.
- **The host answers play, pause, seek and skip on the player,** and then
  reports the change through the delegate as for any other cause, with
  pause reason `user`.
- **Next and previous are offered only while the guest asked for them,**
  and are delivered on the main thread.
- **Artwork is read once,** when it's set. A file that changes later
  isn't looked at again.
- **A player with `playsInBackground` isn't paused for the background,**
  where the manifest allows. It holds the app while it plays.
- **Nothing is shown for a player with no source.**
- **Releasing the player ends all of it.**

## The manifest

```swift
capabilities: [.audio(background: true)]
```

`.audio` is the capability every player requires
([MediaPlayer](MediaPlayer.md)). `AppManifest` doesn't have it yet; it
arrives with the player. It has no usage text and prompts for nothing.

| | `.audio` | with `background` |
|---|---|---|
| iOS | nothing | `UIBackgroundModes: audio` |
| macOS | nothing | nothing: a Mac app isn't suspended |
| Android | nothing | a media playback service, `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` |
| Linux | the sound server's socket | a name on the session bus for MPRIS, and not being stopped while playing |
| Browser | nothing | nothing |

## Per host

| | Notes |
|---|---|
| iOS / macOS | The audio session's category is `playback`, as the player design says. With `background`, the session stays active while a background player plays. `MPNowPlayingInfoCenter` is filled from the info and the player: elapsed time, duration and rate are set at each state change, not on a timer. `MPRemoteCommandCenter`'s play, pause, toggle, change-position and skip commands act on the `AVPlayer`; next and previous go to the delegate. Interruption notifications pause, and resume when they say to. |
| Android | Media3's `MediaSessionService` holds the `ExoPlayer` and the session, which gives the notification, the lock screen and media buttons together. Play, pause and seek are the session's own; next and previous are forwarded. Audio focus pauses and resumes. |
| Linux | The host owns `org.mpris.MediaPlayer2.<app id>` on the session bus: `Metadata`, `PlaybackStatus`, `Position`, and `Play`, `Pause`, `Seek`, `SetPosition`, `Next`, `Previous`. The shell shows it and sends the media keys. Artwork is written to a file the shell can read and named by `mpris:artUrl`. The shell and the background service leave an app alone while its status is playing. |
| Browser | `navigator.mediaSession`: `metadata` with the artwork as a blob URL, `setPositionState`, and action handlers for `play`, `pause`, `seekto`, `seekbackward`, `seekforward`, `nexttrack`, `previoustrack`. `canPlayInBackground` is true: a tab that's playing goes on. |

## Not in this design

- **A queue the host plays through,** for gapless albums and for going on
  to the next track with the guest stopped. The app loads each track
  itself, and there's a short gap.
- **Ratings, likes and other custom buttons.**
- **Picture in picture,** and playing to another device.
- **Starting playback from a button when the app isn't running.** Every
  platform's controls go when the app does.
- **Choosing the output:** speaker, headphones, a Bluetooth device.
- **Mixing with other apps' sound,** and lowering it under speech. A
  player takes the sound, as the player design says.
- **A browsable library for cars** (CarPlay, Android Auto).

## Questions for review

1. **Additions to `MediaPlayer`,** not a contract of their own. The
   alternative is a `NowPlaying` contract an app fills in itself, as
   Apple's is, which lets an app show something no player is playing.
2. **The host answers play, pause and seek itself.** The alternative
   sends every button to the app, which could refuse one, and makes each
   wait for the guest.
3. **No queue.** A music app then has a gap between tracks, and can't go
   on to the next track once the system has stopped it.
4. **This answers the player design's seventh question:** background
   playback is in the first version, since the music app needs it.
5. **Build order.** None of this can be built before the player. The
   player design's other six questions are still open.
