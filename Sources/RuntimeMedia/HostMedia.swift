import Dispatch
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// What an engine is asked to play, checked and found.
public enum HostMediaSource: Equatable, Sendable {

    /// `http` or `https`, which the app's manifest allows.
    case url(String)

    /// An absolute path, of a file that's there; or what
    /// `HostMediaPlayback.findFile` gave, for a host whose files aren't all
    /// paths.
    case file(path: String)

    case data([UInt8], mimeType: String)
}

/// One of the platform's players: an `AVPlayer`, a GStreamer `playbin`.
/// Everything is called on the main thread.
///
/// It reports what happens to the `HostMediaPlayback` it was made for,
/// on the main thread: `loaded`, `stateChanged`, `timeChanged`,
/// `bufferChanged`, `ended` and `failed`.
public protocol MediaEngine: AnyObject {

    /// Starts loading, paused at the start; then calls `loaded` or `failed`.
    func load(_ source: HostMediaSource)

    func unload()

    func play()

    func pause()

    /// `true` when playback is there.
    func seek(to position: Double, completion: @escaping (Bool) -> Void)

    /// Where playback is now, in seconds.
    var currentTime: Double { get }

    func setRate(_ rate: Float)

    func setVolume(_ volume: Float)

    func setMuted(_ muted: Bool)

    func setLooping(_ looping: Bool)

    /// How often to call `timeChanged` while playing.
    func setTimeUpdateInterval(_ seconds: Double)
}

/// A picture for what's playing, found.
public enum HostArtwork: Equatable, Sendable {

    /// An absolute path, or what `HostMediaPlayback.findFile` gave.
    case file(path: String)

    case data([UInt8], mimeType: String)
}

/// What the system shows as playing: what the app said, and what the host
/// knows of the player.
public struct HostNowPlaying: Equatable, Sendable {

    /// The player's identifier.
    public var player: Int32

    public var title: String
    public var artist: String?
    public var album: String?
    public var artwork: HostArtwork?

    /// The buttons to offer beyond play, pause and seeking.
    public var commands: MediaRemoteCommands
    public var skipBackward: Double
    public var skipForward: Double

    /// Seconds, as of this report. `duration` is `nil` for a live stream.
    public var position: Double
    public var duration: Double?

    /// How fast it's advancing; 0 when it isn't.
    public var rate: Float

    public var isPlaying: Bool
}

/// A button pressed where the system shows what's playing, on headphones
/// or on a keyboard.
public enum HostRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case seek(to: Double)
    case skipBackward
    case skipForward
    case next
    case previous
}

/// The platform's side of media: its players, and where it shows what's
/// playing. Everything is called on the main thread.
public protocol MediaPlatform: AnyObject {

    /// A player with nothing loaded, which reports to `player`.
    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine

    func canPlay(_ mimeType: String) -> MediaSupport

    /// Shows what's playing, with its buttons; `nil` shows nothing. Called
    /// when what the app said changes and at each change of state, not on
    /// a timer.
    func showNowPlaying(_ nowPlaying: HostNowPlaying?)
}

public extension MediaPlatform {

    /// Nowhere to show it.
    func showNowPlaying(_ nowPlaying: HostNowPlaying?) { }
}

/// The `MediaPlayback` contract over a host's `MediaPlatform`: what every
/// host written in Swift shares.
///
/// It checks and finds each source before an engine sees it, remembers a
/// `play()` that came too early, answers each seek once, keeps which
/// player is the app's now-playing one and answers its buttons, and applies
/// the rules for the background, interruptions and unplugged headphones.
///
/// ```swift
/// HostMediaPlayback.platform = MyPlayers()
/// HostMediaPlayback.clock = runtime.clock
/// HostMediaPlayback.allowsNetwork = declared.contains(.network)
/// HostMediaPlayback.allowsBackground = audioOptions["background"] == "true"
/// HostMediaModule.register(in: runtime)
///
/// // From the platform:
/// HostMediaPlayback.applicationDidEnterBackground()
/// HostMediaPlayback.remote(.togglePlayPause)
/// // For a `VideoPlayer` node's `player` prop:
/// let engine = HostMediaPlayback.player(for: identifier)?.engine
/// ```
///
/// Main thread only.
public final class HostMediaPlayback: MediaPlayback {

    // MARK: The host's settings

    /// The platform's players. Without one, every load fails with
    /// `unavailable`.
    nonisolated(unsafe) public static var platform: (any MediaPlatform)?

    /// The clock the guest's `Clock` contract reads, so the times reported
    /// are on its timeline.
    nonisolated(unsafe) public static var clock: (any HostClock)?

    /// Whether the manifest declares `.network`: a URL needs it.
    nonisolated(unsafe) public static var allowsNetwork = false

    /// Whether the manifest says `.audio(background: true)`.
    nonisolated(unsafe) public static var allowsBackground = false

    /// Where a file `Files` names is, as the engine takes it: a path, or a
    /// URI for a host whose files aren't all paths (an Android app's
    /// bundle is its APK's assets, a picked document a content URI). It
    /// fails as `Files` would, and with `notFound` for a directory. The
    /// default is `HostFiles`' path.
    nonisolated(unsafe) public static var findFile: (Int32, String) throws(FileError) -> String = findPath

    /// `HostFiles`' path of a file, checked to be one.
    public static func findPath(_ directory: Int32, _ path: String) throws(FileError) -> String {
        let found = try HostFiles.path(of: directory, path: path)
        guard HostFiles.kind(ofItemAt: found) == .file else {
            throw .notFound
        }
        return found
    }

    nonisolated(unsafe) private static var players: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    /// The player the app last described, and its identifier, which is
    /// still known while that player is being destroyed.
    nonisolated(unsafe) private static weak var described: HostMediaPlayback?

    nonisolated(unsafe) private static var describedNumber: Int32?

    /// The players an interruption paused, to resume.
    nonisolated(unsafe) private static var interrupted: [Weak] = []

    private struct Weak {
        weak var player: HostMediaPlayback?
    }

    // MARK: A player

    private let delegate: any MediaPlaybackDelegate

    /// The platform's player, for whatever shows its picture.
    public private(set) var engine: (any MediaEngine)?

    private let number: Int32

    public private(set) var state = MediaState.empty

    /// A `play()` that came before the source was ready.
    private var wantsPlay = false

    public private(set) var playsInBackground = false

    /// Why the next pause the engine reports happened, when it wasn't the
    /// guest that asked.
    private var pendingPauseReason: MediaPauseReason?

    /// Why it was last reported paused.
    private var pauseReason = MediaPauseReason.requested

    /// The seek that hasn't been answered.
    private var pendingSeek: Int32?

    private var info: (title: String, artist: String?, album: String?)?
    private var artwork: HostArtwork?
    private var commands: MediaRemoteCommands = []
    private var skipBackward = 0.0
    private var skipForward = 0.0

    private var duration: Double?
    private var rate: Float = 1

    init(delegate: any MediaPlaybackDelegate) {
        self.delegate = delegate
        self.number = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.players[number] = Weak(player: self)
        self.engine = Self.platform?.makeEngine(for: self)
    }

    deinit {
        // The guest released it: the platform's player goes, and what it
        // showed as playing.
        engine?.unload()
        Self.players[number] = nil
        if Self.describedNumber == number {
            Self.describedNumber = nil
            Self.platform?.showNowPlaying(nil)
        }
    }

    public static func make(_ delegate: any MediaPlaybackDelegate) -> HostMediaPlayback {
        HostMediaPlayback(delegate: delegate)
    }

    public static func canPlay(_ mimeType: String) -> Int32 {
        (platform?.canPlay(mimeType) ?? .no).rawValue
    }

    public static func canPlayInBackground() -> Bool {
        allowsBackground && platform != nil
    }

    public func identifier() -> Int32 {
        number
    }

    // MARK: Host side

    /// The player a `VideoPlayer` node names, while the guest holds it.
    public static func player(for identifier: Int32) -> HostMediaPlayback? {
        players[identifier]?.player
    }

    /// Whether a player is playing on in the background: it holds the app,
    /// as a background activity does.
    public static var holdsApp: Bool {
        live.contains { $0.playsInBackground && ($0.state == .playing || $0.state == .buffering) }
    }

    /// The app left the front: every player that doesn't play in the
    /// background is paused, and stays paused when the app comes back.
    public static func applicationDidEnterBackground() {
        for player in live where !player.playsInBackground {
            player.pause(for: .background)
        }
    }

    /// A call, an alarm, another app that plays: what's playing pauses.
    public static func interruptionBegan() {
        interrupted = live.filter { $0.isActive }.map { Weak(player: $0) }
        for player in live {
            player.pause(for: .interrupted)
        }
    }

    /// The interruption is over. With `shouldResume`, as the system says,
    /// what it paused plays again.
    public static func interruptionEnded(shouldResume: Bool) {
        let paused = interrupted.compactMap(\.player)
        interrupted = []
        guard shouldResume else { return }
        for player in paused where player.state == .paused {
            player.engine?.play()
        }
    }

    /// Headphones were unplugged: what's playing pauses.
    public static func outputRouteWasLost() {
        for player in live {
            player.pause(for: .routeChanged)
        }
    }

    /// A button where the system shows what's playing. The host answers
    /// play, pause, seeking and skipping on the now-playing player itself;
    /// next and previous go to the guest, when it offered them. Returns
    /// whether anything answered.
    @discardableResult
    public static func remote(_ command: HostRemoteCommand) -> Bool {
        guard let player = described, player.info != nil, let engine = player.engine, player.state != .empty else {
            return false
        }
        switch command {
        case .play:
            engine.play()
        case .pause:
            player.pause(for: .user)
        case .togglePlayPause:
            if player.isActive {
                player.pause(for: .user)
            } else {
                engine.play()
            }
        case .seek(let position):
            player.seekFromHost(to: position)
        case .skipBackward:
            guard player.commands.contains(.skip) else { return false }
            player.seekFromHost(to: engine.currentTime - player.skipBackward)
        case .skipForward:
            guard player.commands.contains(.skip) else { return false }
            player.seekFromHost(to: engine.currentTime + player.skipForward)
        case .next:
            guard player.commands.contains(.next) else { return false }
            player.delegate.didReceiveCommand(1)
        case .previous:
            guard player.commands.contains(.previous) else { return false }
            player.delegate.didReceiveCommand(2)
        }
        return true
    }

    /// Forgets the platform and the settings, for tests and for a host
    /// that starts the guest again.
    public static func reset() {
        platform = nil
        clock = nil
        allowsNetwork = false
        allowsBackground = false
        findFile = findPath
        described = nil
        describedNumber = nil
        interrupted = []
    }

    private static var live: [HostMediaPlayback] {
        players.values.compactMap(\.player)
    }

    /// Playing, or about to.
    private var isActive: Bool {
        state == .playing || state == .buffering
    }

    private func pause(for reason: MediaPauseReason) {
        guard isActive, let engine else { return }
        pendingPauseReason = reason
        wantsPlay = false
        engine.pause()
    }

    private func seekFromHost(to position: Double) {
        var target = max(position, 0)
        if let duration {
            target = min(target, duration)
        }
        engine?.seek(to: target) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.timeChanged(position: engine.currentTime, rate: self.isActive ? self.rate : 0)
            self.publish()
        }
    }

    // MARK: From the engine

    /// The source can be played. `duration` is `nil` for a live stream.
    public func loaded(duration: Double?, width: Int, height: Int, hasAudio: Bool, hasVideo: Bool) {
        guard state == .loading else { return }
        self.duration = duration
        delegate.didLoad(duration ?? -1, width: Int32(clamping: width), height: Int32(clamping: height), hasAudio: hasAudio, hasVideo: hasVideo)
        state = .paused
        pauseReason = .requested
        delegate.didChangeState(MediaState.paused.rawValue, reason: MediaPauseReason.requested.rawValue)
        publish()
        if wantsPlay {
            wantsPlay = false
            engine?.play()
        }
    }

    /// The engine is playing, buffering or paused. For a pause that only
    /// the engine knows the cause of, such as the platform's controls, it
    /// says why.
    public func stateChanged(_ new: MediaState, reason: MediaPauseReason = .requested) {
        guard state != .empty, state != .loading || new == .failed else { return }
        var reason = reason
        if new == .paused, let pending = pendingPauseReason {
            reason = pending
        }
        if new != .buffering {
            pendingPauseReason = nil
        }
        // Said once: a pause is said again only for another reason.
        guard new != state || (new == .paused && reason != pauseReason) else { return }
        state = new
        if new == .paused {
            pauseReason = reason
        }
        delegate.didChangeState(new.rawValue, reason: new == .paused ? reason.rawValue : 0)
        publish()
    }

    /// Playback is at `position`, advancing at `rate` (0 when it isn't).
    public func timeChanged(position: Double, rate: Float) {
        guard state != .empty else { return }
        delegate.didChangeTime(position, timestamp: Self.now(), rate: rate)
    }

    /// Seconds loaded past the current position.
    public func bufferChanged(_ seconds: Double) {
        guard state != .empty else { return }
        delegate.didChangeBuffer(seconds)
    }

    /// Reached the end, and isn't looping.
    public func ended() {
        guard state != .empty, state != .loading else { return }
        pendingPauseReason = nil
        state = .paused
        pauseReason = .ended
        delegate.didChangeState(MediaState.paused.rawValue, reason: MediaPauseReason.ended.rawValue)
        publish()
        delegate.didEnd()
    }

    /// The source can't be played, or playback broke.
    public func failed(_ error: MediaError) {
        guard state != .empty else { return }
        fail(error)
    }

    private func fail(_ error: MediaError) {
        wantsPlay = false
        state = .failed
        delegate.didChangeState(MediaState.failed.rawValue, reason: 0)
        delegate.didFail(error.code.rawValue, message: error.message)
        publish()
    }

    private static func now() -> Int64 {
        clock?.now() ?? Int64(clamping: DispatchTime.now().uptimeNanoseconds)
    }

    // MARK: Now playing

    /// Tells the platform what's playing, if this is the player to show.
    private func publish() {
        guard Self.described === self else { return }
        guard let info, state != .empty, let engine else {
            Self.platform?.showNowPlaying(nil)
            return
        }
        Self.platform?.showNowPlaying(HostNowPlaying(
            player: number, title: info.title, artist: info.artist, album: info.album, artwork: artwork,
            commands: commands, skipBackward: skipBackward, skipForward: skipForward,
            position: engine.currentTime, duration: duration, rate: state == .playing ? rate : 0, isPlaying: state == .playing
        ))
    }

    public func setNowPlaying(_ title: String, artist: String?, album: String?) {
        guard !title.isEmpty else {
            info = nil
            artwork = nil
            if Self.described === self {
                Self.described = nil
                Self.describedNumber = nil
                Self.platform?.showNowPlaying(nil)
            }
            return
        }
        info = (title, artist, album)
        // What was said before, of another track, has no picture here.
        artwork = nil
        Self.described = self
        Self.describedNumber = number
        publish()
    }

    public func setArtworkFile(_ directory: Int32, path: String) {
        guard info != nil, let found = try? Self.findFile(directory, path) else {
            return
        }
        artwork = .file(path: found)
        publish()
    }

    public func setArtworkData(_ data: [UInt8], mimeType: String) {
        guard info != nil, !data.isEmpty else { return }
        artwork = .data(data, mimeType: mimeType)
        publish()
    }

    public func setRemoteCommands(_ commands: Int32, skipBackward: Double, skipForward: Double) {
        self.commands = MediaRemoteCommands(rawValue: commands)
        self.skipBackward = max(skipBackward, 0)
        self.skipForward = max(skipForward, 0)
        publish()
    }

    public func setPlaysInBackground(_ enabled: Bool) {
        // Without the manifest's leave it's ignored.
        playsInBackground = enabled && Self.allowsBackground
    }

    // MARK: Playback

    private func begin(_ source: HostMediaSource) {
        guard let engine else {
            state = .loading
            delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
            fail(MediaError(.unavailable, message: "this host has no media players"))
            return
        }
        pendingPauseReason = nil
        duration = nil
        cancelSeek()
        state = .loading
        delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        engine.load(source)
    }

    private func refuse(_ error: MediaError) {
        engine?.unload()
        cancelSeek()
        state = .loading
        delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        fail(error)
    }

    public func loadURL(_ url: String) {
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            refuse(MediaError(.notPermitted, message: "only http and https URLs are played"))
            return
        }
        guard Self.allowsNetwork else {
            refuse(MediaError(.notPermitted, message: "the manifest doesn't declare network"))
            return
        }
        begin(.url(url))
    }

    public func loadFile(_ directory: Int32, path: String) {
        let found: String
        do throws(FileError) {
            found = try Self.findFile(directory, path)
        } catch {
            refuse(MediaError(error == .notPermitted ? .notPermitted : .notFound, message: "no such file"))
            return
        }
        begin(.file(path: found))
    }

    public func loadData(_ data: [UInt8], mimeType: String) {
        guard !data.isEmpty else {
            refuse(MediaError(.decoding, message: "no data"))
            return
        }
        begin(.data(data, mimeType: mimeType))
    }

    public func unload() {
        engine?.unload()
        cancelSeek()
        wantsPlay = false
        pendingPauseReason = nil
        duration = nil
        guard state != .empty else { return }
        state = .empty
        delegate.didChangeState(MediaState.empty.rawValue, reason: 0)
        publish()
    }

    public func play() {
        switch state {
        case .paused, .playing, .buffering:
            engine?.play()
        case .empty, .loading:
            // Remembered: playback starts when it can.
            wantsPlay = true
        case .failed:
            break
        }
    }

    public func pause() {
        wantsPlay = false
        guard isActive else { return }
        engine?.pause()
    }

    private func cancelSeek() {
        if let pending = pendingSeek {
            pendingSeek = nil
            delegate.didSeek(pending, finished: false)
        }
    }

    public func seek(_ position: Double, request: Int32) {
        // Another seek replaces the one that hasn't landed.
        cancelSeek()
        guard let engine, state == .paused || state == .playing || state == .buffering else {
            delegate.didSeek(request, finished: false)
            return
        }
        pendingSeek = request
        engine.seek(to: position) { [weak self] finished in
            guard let self, self.pendingSeek == request else { return }
            self.pendingSeek = nil
            self.timeChanged(position: engine.currentTime, rate: self.state == .playing ? self.rate : 0)
            self.delegate.didSeek(request, finished: finished)
            self.publish()
        }
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        engine?.setRate(rate)
        publish()
    }

    public func setVolume(_ volume: Float) {
        engine?.setVolume(volume)
    }

    public func setMuted(_ muted: Bool) {
        engine?.setMuted(muted)
    }

    public func setLooping(_ looping: Bool) {
        engine?.setLooping(looping)
    }

    public func setTimeUpdateInterval(_ seconds: Double) {
        engine?.setTimeUpdateInterval(max(seconds, 0.01))
    }
}

/// The media module: the contract and its delegate.
public enum HostMediaModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [MediaPlaybackProxy.descriptor, MediaPlaybackDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        MediaPlaybackProxy.register(HostMediaPlayback.self, in: registrar)
        MediaPlaybackDelegateProxy.registerInterface(in: registrar)
    }

    /// No platform asks the user before an app plays sound.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.audio: GrantedPermission()]
    }
}
