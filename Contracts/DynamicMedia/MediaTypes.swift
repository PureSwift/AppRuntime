import DynamicFiles

/// Guest-side names for what the `MediaPlayback` contract carries.

/// What a player plays.
public enum MediaSource: Equatable, Sendable {

    /// `http` or `https`. Needs `.network` in the manifest.
    case url(String)

    /// A file: in the app's own directories, its bundle, or a document the
    /// user picked.
    case file(FilePath)

    /// A whole file's bytes and its MIME type, for a sound the app made or
    /// already has in memory.
    case data([UInt8], type: String)

    /// A file in the app's bundle.
    public static func resource(_ path: String) -> MediaSource {
        .file(.bundle / path)
    }
}

/// Whether a player has something to play.
public enum MediaStatus: Sendable {

    /// No source.
    case empty

    /// A source, not yet playable.
    case loading

    case ready

    /// See the player's `error`.
    case failed
}

/// What the host's player is doing: the contract's states.
public enum MediaState: Int32, Sendable {
    case empty = 0
    case loading = 1
    case paused = 2
    case playing = 3
    /// Asked to play, and waiting for data.
    case buffering = 4
    case failed = 5
}

/// Why a player isn't playing.
public enum MediaPauseReason: Int32, Sendable {

    /// The app called `pause()`, or never called `play()`.
    case requested = 0

    /// The platform's controls, a headset button, the lock screen.
    case user = 1

    /// A call, or another app took the sound.
    case interrupted = 2

    /// The app left the front, and the player doesn't play in the
    /// background.
    case background = 3

    case ended = 4

    /// The platform refused to start: a browser, outside a user's action.
    case notAllowed = 5

    /// Headphones were unplugged.
    case routeChanged = 6
}

/// Why a source couldn't be played.
public struct MediaError: Error, Equatable, Sendable {

    public enum Code: Int32, Sendable {
        case unknown = 0
        /// No such file, or the server said so.
        case notFound = 1
        case unsupportedFormat = 2
        /// The connection failed or was lost.
        case network = 3
        /// A URL without `.network`, or a scheme that isn't `http` or
        /// `https`; a document the app doesn't hold.
        case notPermitted = 4
        /// The data is damaged.
        case decoding = 5
        /// No output device, or no capability.
        case unavailable = 6
    }

    public var code: Code

    /// The host's own words, for a log.
    public var message: String

    public init(_ code: Code, message: String = "") {
        self.code = code
        self.message = message
    }
}

/// Whether a host plays a kind of media.
public enum MediaSupport: Int32, Sendable {
    case no = 0
    case maybe = 1
    case probably = 2
}

/// A picture's size, in its own pixels.
public struct MediaSize: Equatable, Sendable {

    public var width: Int

    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Sound alone.
    public static let zero = MediaSize(width: 0, height: 0)
}

/// Something that happened to a player, for code that follows one.
public enum MediaEvent: Equatable, Sendable {

    /// The source can be played. `duration` is `nil` for a live stream.
    case loaded(duration: Double?, videoSize: MediaSize)

    case playing

    case paused(MediaPauseReason)

    case buffering

    /// A seek landed, at this time.
    case seeked(Double)

    /// Reached the end, and isn't looping.
    case ended

    case failed(MediaError)

    /// The user pressed next, or previous, where the system shows what's
    /// playing.
    case nextTrack
    case previousTrack
}

/// How a picture fits the space its view is given.
public enum VideoScaling: String, Sendable {

    /// All of it, inside the space.
    case fit

    /// The space filled, the picture cropped.
    case fill

    /// The space filled, the picture distorted.
    case stretch
}

/// What a `VideoPlayer` shows over the picture.
public enum VideoControls: String, Sendable {

    /// The platform's own: play, pause, a scrubber, full screen where it
    /// has one.
    case platform

    /// Only the picture, for an app that draws its own.
    case none
}

/// What a player is playing, for the system to show where it shows what's
/// playing: the lock screen, the shell's media controls, a car's display.
///
/// The position, duration and rate aren't here: the host reports the
/// player's own.
public struct NowPlayingInfo: Equatable, Sendable {

    public var title: String

    public var artist: String?

    public var album: String?

    public var artwork: NowPlayingArtwork?

    public init(title: String, artist: String? = nil, album: String? = nil, artwork: NowPlayingArtwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }
}

/// A picture for what's playing: a file or bytes, not a URL.
public enum NowPlayingArtwork: Equatable, Sendable {

    /// In the bundle, the app's files, or a document.
    case file(FilePath)

    /// An image file's bytes and its MIME type, such as a picture from a
    /// song's tags.
    case data([UInt8], type: String)
}

/// The buttons a host offers beyond play, pause and seeking.
public struct MediaRemoteCommands: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let next = MediaRemoteCommands(rawValue: 1 << 0)
    public static let previous = MediaRemoteCommands(rawValue: 1 << 1)
    /// Back and forward by the player's intervals.
    public static let skip = MediaRemoteCommands(rawValue: 1 << 2)
}
