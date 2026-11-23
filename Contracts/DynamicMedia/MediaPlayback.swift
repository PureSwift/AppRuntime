import DynamicRuntime

/// One media player in the host: a song, a podcast or a video, decoded,
/// timed and shown by the host (`Documentation/Contracts/MediaPlayer.md`,
/// with `NowPlaying.md`'s additions). App code uses `MediaPlayer`,
/// `VideoPlayer` and `AudioPlayer`, which wrap this contract.
///
/// Media is the host's, start to finish: no sample and no frame crosses to
/// the guest. The guest says what to play and follows along through the
/// delegate, which the host calls on the main thread whoever caused the
/// change: the guest, the user with the platform's controls, or the system.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `AVPlayer`, shown by AVKit |
/// | Android | Media3's `ExoPlayer`, shown by its `PlayerView` |
/// | Linux | a GStreamer `playbin` |
/// | Browser | a `<video>` or `<audio>` element |
@DynamicRuntime("org.pureswift.media.Playback", requires: .audio)
public protocol MediaPlayback: AnyObject {

    /// A player with nothing loaded. The host keeps `delegate` while the
    /// player lives, and destroys the player when the guest releases it.
    static func make(_ delegate: MediaPlaybackDelegate) -> Self

    /// Whether this host plays a MIME type: a `MediaSupport` raw value.
    static func canPlay(_ mimeType: String) -> Int32

    /// Whether this app may play in the background on this host: whether
    /// its manifest says `.audio(background: true)`, and the host can.
    static func canPlayInBackground() -> Bool

    /// What a `VideoPlayer` node carries to say which player it shows.
    func identifier() -> Int32

    // One source at a time. Each replaces the last, and is answered by
    // `didLoad` or `didFail`.

    /// `http` or `https`. Needs `.network` in the manifest.
    func loadURL(_ url: String)

    /// A file as `Files` names it: a `FileDirectory` raw value and a path.
    func loadFile(_ directory: Int32, path: String)

    /// A whole file's bytes.
    func loadData(_ data: [UInt8], mimeType: String)

    func unload()

    /// Before the source is ready, it's remembered: playback starts when
    /// it can.
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

    // MARK: Now playing

    /// Says what this player is playing, and makes it the app's now-playing
    /// player: what the system shows on the lock screen and in its media
    /// controls. An empty title takes it away.
    func setNowPlaying(_ title: String, artist: String?, album: String?)

    /// The artwork of what was last said to be playing: a file as `Files`
    /// names it. Read once, now.
    func setArtworkFile(_ directory: Int32, path: String)

    func setArtworkData(_ data: [UInt8], mimeType: String)

    /// The buttons the system offers beyond play, pause and seeking, which
    /// the host answers itself. `commands` are bits of
    /// `MediaRemoteCommands`. The intervals are seconds.
    func setRemoteCommands(_ commands: Int32, skipBackward: Double, skipForward: Double)

    /// Goes on playing when the app leaves the front. Ignored without the
    /// manifest's leave.
    func setPlaysInBackground(_ enabled: Bool)

    // MARK: Tracks

    /// Chooses a track of the loaded file. `kind`: 0 audio, 1 subtitles.
    /// `index` into what `didChangeTracks` last listed; -1 is the file's
    /// default for audio, and off for subtitles.
    func selectTrack(_ kind: Int32, index: Int32)
}

/// What a host that hasn't implemented tracks does: nothing.
public extension MediaPlayback {

    func selectTrack(_ kind: Int32, index: Int32) { }
}

/// What a player does, from the host. Called on the main thread.
@DynamicCallback("org.pureswift.media.PlaybackDelegate")
public protocol MediaPlaybackDelegate: AnyObject {

    /// The source can be played. `duration` is negative when it isn't
    /// known, as for a live stream. Sizes are the picture's pixels.
    func didLoad(_ duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool)

    /// A `MediaState` raw value, and for a pause its `MediaPauseReason`.
    func didChangeState(_ state: Int32, reason: Int32)

    /// Playback was at `position` seconds at `timestamp`, nanoseconds on
    /// the `Clock.now()` timeline, advancing at `rate` (0 when it isn't).
    func didChangeTime(_ position: Double, timestamp: Int64, rate: Float)

    /// Seconds loaded past the current position.
    func didChangeBuffer(_ seconds: Double)

    /// `finished` is false when another seek replaced this one.
    func didSeek(_ request: Int32, finished: Bool)

    /// Reached the end, and isn't looping.
    func didEnd()

    /// `code` is a `MediaError.Code` raw value.
    func didFail(_ code: Int32, message: String)

    /// A button the host can't answer itself: 1 next, 2 previous.
    func didReceiveCommand(_ command: Int32)

    /// What the loaded file has, and which are chosen: after `didLoad`, and
    /// whenever the choice changes, from the guest or the platform's
    /// controls. Names and languages are in step; an empty language is
    /// none. `selected…` is an index, or -1: the default audio, or no
    /// subtitles.
    func didChangeTracks(_ audioNames: [String], audioLanguages: [String], subtitleNames: [String], subtitleLanguages: [String], selectedAudio: Int32, selectedSubtitle: Int32)
}

/// What a delegate that doesn't follow tracks does: nothing.
public extension MediaPlaybackDelegate {

    func didChangeTracks(_ audioNames: [String], audioLanguages: [String], subtitleNames: [String], subtitleLanguages: [String], selectedAudio: Int32, selectedSubtitle: Int32) { }
}
