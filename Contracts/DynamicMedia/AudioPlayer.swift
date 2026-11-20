#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#endif

/// Hears when an `AudioPlayer` finishes or can't play, as
/// `AVAudioPlayerDelegate` does.
public protocol AudioPlayerDelegate: AnyObject {

    /// The sound played to its end, loops included.
    func audioPlayerDidFinishPlaying(_ player: AudioPlayer, successfully flag: Bool)

    /// The source couldn't be played.
    func audioPlayerDecodeErrorDidOccur(_ player: AudioPlayer, error: MediaError)
}

public extension AudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AudioPlayer, successfully flag: Bool) { }

    func audioPlayerDecodeErrorDidOccur(_ player: AudioPlayer, error: MediaError) { }
}

/// Plays one sound, with `AVAudioPlayer`'s methods and properties, so code
/// written for it ports by dropping the prefix.
///
/// ```swift
/// let player = AudioPlayer(.resource("music/theme.mp3"))
/// player.numberOfLoops = -1
/// player.volume = 0.8
/// player.play()
/// ```
///
/// Where it differs:
///
/// - Making one never throws, and `duration` starts at 0: whether a file
///   can be played isn't known until it's loaded. `isReady` says when, and
///   an unplayable one calls `audioPlayerDecodeErrorDidOccur`.
/// - It takes a URL too. It's the same player underneath as `MediaPlayer`:
///   `mediaPlayer`.
/// - No `pan`, metering or `play(atTime:)`.
/// - The delegate is held strongly: Embedded Swift has no weak references.
///   Set it to `nil` to let it go.
public final class AudioPlayer {

    /// The player underneath, for what this doesn't have: `events`,
    /// `nowPlaying`, buffering.
    public let mediaPlayer = MediaPlayer()

    public var delegate: (any AudioPlayerDelegate)?

    /// How many times it starts again after the first: 0 plays once, and a
    /// negative number plays until it's stopped.
    public var numberOfLoops = 0 {
        didSet {
            remaining = numberOfLoops
            mediaPlayer.isLooping = numberOfLoops < 0
        }
    }

    /// The loops still to play.
    private var remaining = 0

    public init(_ source: MediaSource) {
        // The closures don't keep this alive: the media player is this
        // object's own, and goes with it.
        let unretained = Unmanaged.passUnretained(self)
        mediaPlayer.onEnd = {
            unretained.takeUnretainedValue().finished()
        }
        mediaPlayer.onFailure = { error in
            let player = unretained.takeUnretainedValue()
            player.delegate?.audioPlayerDecodeErrorDidOccur(player, error: error)
        }
        mediaPlayer.load(source)
    }

    deinit {
        mediaPlayer.onEnd = nil
        mediaPlayer.onFailure = nil
    }

    private func finished() {
        if remaining > 0 {
            remaining -= 1
            mediaPlayer.seek(to: 0) { _ in }
            mediaPlayer.play()
        } else {
            remaining = numberOfLoops
            delegate?.audioPlayerDidFinishPlaying(self, successfully: true)
        }
    }

    /// Whether the source has loaded: `duration` is known from then.
    public var isReady: Bool {
        mediaPlayer.status == .ready
    }

    public var isPlaying: Bool {
        mediaPlayer.isPlaying
    }

    /// Seconds; 0 until the source has loaded.
    public var duration: Double {
        mediaPlayer.duration ?? 0
    }

    public var currentTime: Double {
        get { mediaPlayer.currentTime }
        set { mediaPlayer.currentTime = newValue }
    }

    public var volume: Float {
        get { mediaPlayer.volume }
        set { mediaPlayer.volume = newValue }
    }

    public var rate: Float {
        get { mediaPlayer.rate }
        set { mediaPlayer.rate = newValue }
    }

    /// The source began loading when the player was made; there's nothing
    /// more to prepare.
    @discardableResult
    public func prepareToPlay() -> Bool {
        mediaPlayer.status != .failed
    }

    @discardableResult
    public func play() -> Bool {
        guard mediaPlayer.status != .failed else { return false }
        mediaPlayer.play()
        return true
    }

    public func pause() {
        mediaPlayer.pause()
    }

    /// Pauses, and goes back to the start.
    public func stop() {
        mediaPlayer.pause()
        mediaPlayer.seek(to: 0) { _ in }
        remaining = numberOfLoops
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// What happens to the player: the media player's `events`.
    public var events: EventStream<MediaEvent, Never> {
        mediaPlayer.events
    }
    #endif
}
