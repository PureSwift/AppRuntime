import DynamicFiles
import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Plays a song, a podcast or a video: `AVPlayer`'s place. Show its picture
/// with `VideoPlayer(player)`; without a view it still plays its sound.
///
/// ```swift
/// let player = MediaPlayer()
/// player.load(.url("https://example.com/trailer.mp4"))
/// player.play()
/// ```
///
/// It's observable: a view that reads `isPlaying` or `currentTime` is
/// updated when they change. Code follows one with `events`, or with the
/// `onEnd` and `onFailure` closures.
///
/// The player lives in the host (`MediaPlayback`), which is made the first
/// time it's used. Releasing the `MediaPlayer` stops it and frees the
/// host's player.
///
/// It's guest-side only. The guest is single-threaded (§6.4).
public final class MediaPlayer: Observable {

    // MARK: State

    /// Whether there's something to play.
    public var status: MediaStatus {
        registrar.access(self, propertyIndex: 0)
        return values.status
    }

    /// Sound or picture is advancing.
    public var isPlaying: Bool {
        registrar.access(self, propertyIndex: 1)
        return values.isPlaying
    }

    /// It would be playing, and is waiting for data.
    public var isBuffering: Bool {
        registrar.access(self, propertyIndex: 2)
        return values.isBuffering
    }

    /// Why it isn't playing.
    public var pauseReason: MediaPauseReason {
        registrar.access(self, propertyIndex: 3)
        return values.pauseReason
    }

    /// Seconds into the source. Exact when read: it's worked out from the
    /// host's last report and the clock. For views it changes a few times
    /// a second, every `timeUpdateInterval`, and at every seek, pause and
    /// resume. Set it to seek.
    public var currentTime: Double {
        get {
            registrar.access(self, propertyIndex: 4)
            return timeNow()
        }
        set {
            seek(to: newValue) { _ in }
        }
    }

    /// Seconds; `nil` until it's known, and for a live stream.
    public var duration: Double? {
        registrar.access(self, propertyIndex: 5)
        return values.duration
    }

    /// Seconds loaded past `currentTime`.
    public var bufferedTime: Double {
        registrar.access(self, propertyIndex: 6)
        return values.bufferedTime
    }

    /// The picture's own size; zero for sound alone.
    public var videoSize: MediaSize {
        registrar.access(self, propertyIndex: 7)
        return values.videoSize
    }

    public var hasVideo: Bool {
        registrar.access(self, propertyIndex: 7)
        return values.hasVideo
    }

    public var hasAudio: Bool {
        registrar.access(self, propertyIndex: 7)
        return values.hasAudio
    }

    /// 0.5 to 2, with the pitch kept. 1 by default.
    public var rate: Float {
        get {
            registrar.access(self, propertyIndex: 8)
            return values.rate
        }
        set {
            let rate = min(max(newValue, 0.5), 2)
            guard rate != values.rate else { return }
            mutate(8) { values.rate = rate }
            playback.setRate(rate)
        }
    }

    /// 0 to 1.
    public var volume: Float {
        get {
            registrar.access(self, propertyIndex: 9)
            return values.volume
        }
        set {
            let volume = min(max(newValue, 0), 1)
            guard volume != values.volume else { return }
            mutate(9) { values.volume = volume }
            playback.setVolume(volume)
        }
    }

    public var isMuted: Bool {
        get {
            registrar.access(self, propertyIndex: 10)
            return values.isMuted
        }
        set {
            guard newValue != values.isMuted else { return }
            mutate(10) { values.isMuted = newValue }
            playback.setMuted(newValue)
        }
    }

    /// Starts again at the end.
    public var isLooping: Bool {
        get {
            registrar.access(self, propertyIndex: 11)
            return values.isLooping
        }
        set {
            guard newValue != values.isLooping else { return }
            mutate(11) { values.isLooping = newValue }
            playback.setLooping(newValue)
        }
    }

    /// Why it failed, when `status` is `.failed`.
    public var error: MediaError? {
        registrar.access(self, propertyIndex: 12)
        return values.error
    }

    // MARK: Tracks

    /// The loaded file's audio tracks. Empty before a file is loaded, and
    /// for a file with only one.
    public var audioTracks: [MediaTrack] {
        registrar.access(self, propertyIndex: 14)
        return values.audioTracks
    }

    /// The loaded file's subtitles and captions.
    public var subtitleTracks: [MediaTrack] {
        registrar.access(self, propertyIndex: 14)
        return values.subtitleTracks
    }

    /// The audio being played: `nil` is the file's default. A choice made
    /// in the platform's controls shows here too. A track that isn't one
    /// of `audioTracks` is ignored. Loading another file goes back to its
    /// default.
    public var selectedAudioTrack: MediaTrack? {
        get {
            registrar.access(self, propertyIndex: 15)
            return values.selectedAudio
        }
        set {
            guard newValue != values.selectedAudio, newValue.map(values.audioTracks.contains) ?? true else { return }
            mutate(15) { values.selectedAudio = newValue }
            playback.selectTrack(0, index: newValue?.index ?? -1)
        }
    }

    /// The subtitles shown, drawn by the host over the picture: `nil` is
    /// none. As `selectedAudioTrack`.
    public var selectedSubtitleTrack: MediaTrack? {
        get {
            registrar.access(self, propertyIndex: 16)
            return values.selectedSubtitle
        }
        set {
            guard newValue != values.selectedSubtitle, newValue.map(values.subtitleTracks.contains) ?? true else { return }
            mutate(16) { values.selectedSubtitle = newValue }
            playback.selectTrack(1, index: newValue?.index ?? -1)
        }
    }

    // MARK: Now playing

    /// What this player is playing, for the system to show where it shows
    /// what's playing. Setting it makes this the app's now-playing player;
    /// `nil` takes it away, and so does `unload()`. Set it when the source
    /// changes: the position, duration and rate are the host's to report.
    public var nowPlaying: NowPlayingInfo? {
        get {
            registrar.access(self, propertyIndex: 13)
            return values.nowPlaying
        }
        set {
            guard newValue != values.nowPlaying else { return }
            mutate(13) { values.nowPlaying = newValue }
            describe(newValue)
        }
    }

    /// Goes on playing when the app leaves the front. It needs the
    /// manifest's leave, `.audio(background: true)`; without it, this does
    /// nothing, and the host pauses the player then with reason
    /// `.background`. A video's picture stops; its sound goes on.
    public var playsInBackground = false {
        didSet {
            guard playsInBackground != oldValue else { return }
            playback.setPlaysInBackground(playsInBackground)
        }
    }

    /// Whether this app may play in the background on this host.
    public static var canPlayInBackground: Bool {
        MediaPlaybackProxy.canPlayInBackground()
    }

    /// Called when the user presses next, or previous, where the system
    /// shows what's playing. The button is offered while the closure is
    /// set.
    public var onNextTrack: (() -> Void)? {
        didSet { offerCommands() }
    }

    public var onPreviousTrack: (() -> Void)? {
        didSet { offerCommands() }
    }

    /// Offers buttons that skip back and forward by so many seconds, which
    /// the host answers itself.
    public var skipIntervals: (backward: Double, forward: Double)? {
        didSet { offerCommands() }
    }

    // MARK: Following

    /// Called when playback reaches the end and isn't looping: before the
    /// `events` stream's `.ended`.
    public var onEnd: (() -> Void)?

    /// Called when a source can't be played, or playback fails.
    public var onFailure: ((MediaError) -> Void)?

    /// How often `currentTime` changes for views while playing: half a
    /// second by default.
    public var timeUpdateInterval: Double = 0.5 {
        didSet {
            guard timeUpdateInterval != oldValue else { return }
            playback.setTimeUpdateInterval(timeUpdateInterval)
        }
    }

    public init() { }

    deinit {
        receiver.player = nil
        #if !EMBEDDED_NO_CONCURRENCY
        subscribers.finishAll()
        for ticker in tickers {
            ticker.stop()
        }
        #endif
    }

    /// Whether this host plays a MIME type. What every host plays is in
    /// the contract's document; an app that relies on more isn't portable.
    public static func canPlay(_ mimeType: String) -> MediaSupport {
        MediaSupport(rawValue: MediaPlaybackProxy.canPlay(mimeType)) ?? .no
    }

    /// What a `VideoPlayer` node carries to say which player it shows.
    public var identifier: Int32 {
        if let cachedIdentifier {
            return cachedIdentifier
        }
        let identifier = playback.identifier()
        cachedIdentifier = identifier
        return identifier
    }

    // MARK: Playing

    /// Starts loading a source, paused at its start. It replaces the one
    /// before. To play a list, load the next in `onEnd`.
    public func load(_ source: MediaSource) {
        switch source {
        case .url(let url):
            playback.loadURL(url)
        case .file(let path):
            playback.loadFile(path.directory.rawValue, path: path.path)
        case .data(let bytes, let type):
            playback.loadData(bytes, mimeType: type)
        }
    }

    /// Lets go of the source, and of what was said to be playing.
    public func unload() {
        playback.unload()
        if values.nowPlaying != nil {
            mutate(13) { values.nowPlaying = nil }
            describe(nil)
        }
    }

    /// Before the source is ready, it's remembered: playback starts when
    /// it can. A browser starts only inside a user's action, unless the
    /// player is muted; elsewhere this leaves it paused, with reason
    /// `.notAllowed`.
    public func play() {
        playback.play()
    }

    public func pause() {
        playback.pause()
    }

    /// Moves playback. `completion` hears `true` when playback is there,
    /// and `false` when another seek replaced this one.
    public func seek(to time: Double, completion: @escaping (Bool) -> Void) {
        let request = nextRequest
        nextRequest = nextRequest == .max ? 1 : nextRequest + 1
        seeks[request] = completion
        playback.seek(max(time, 0), request: request)
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Moves playback, and returns when it's there: `false` if another
    /// seek replaced this one.
    @discardableResult
    public nonisolated(nonsending) func seek(to time: Double) async -> Bool {
        do {
            return try await withCallback { (callback: Callback<Bool, MediaSeekCancelled>) in
                self.seek(to: time) { callback.resume(returning: $0) }
            } onCancel: { callback in
                callback.resume(throwing: MediaSeekCancelled())
            }
        } catch {
            // The task waiting was cancelled; the seek itself goes on.
            return false
        }
    }

    /// What happens to the player, from when the stream is first awaited:
    /// for a playlist, a state machine, analytics. It doesn't replay; read
    /// the properties for where things stand. Any number can run at once.
    /// It ends when the player is released.
    public var events: EventStream<MediaEvent, Never> {
        let (stream, continuation) = EventStream<MediaEvent, Never>.makeStream()
        let subscribers = self.subscribers
        let id = subscribers.add(continuation)
        continuation.onTermination = {
            subscribers.remove(id)
        }
        return stream
    }

    /// `currentTime`, every `seconds` while playing and once at each seek:
    /// for doing something at regular times. A view reads `currentTime`
    /// instead, and lets it update.
    public func times(every seconds: Double) -> EventStream<Double, Never> {
        let (stream, continuation) = EventStream<Double, Never>.makeStream()
        let ticker = MediaTicker(player: Unmanaged.passUnretained(self), interval: max(seconds, 0.01), continuation: continuation)
        tickers.append(ticker)
        continuation.onTermination = { [receiver] in
            ticker.stop()
            // The player may be gone by now; the receiver knows.
            receiver.player?.takeUnretainedValue().tickers.removeAll { $0 === ticker }
        }
        if values.isPlaying {
            ticker.start()
        }
        return stream
    }
    #endif

    // MARK: The host's player

    private struct Values {
        var status = MediaStatus.empty
        var isPlaying = false
        var isBuffering = false
        var pauseReason = MediaPauseReason.requested
        var duration: Double?
        var bufferedTime = 0.0
        var videoSize = MediaSize.zero
        var hasVideo = false
        var hasAudio = false
        var rate: Float = 1
        var volume: Float = 1
        var isMuted = false
        var isLooping = false
        var error: MediaError?
        var nowPlaying: NowPlayingInfo?
        var audioTracks: [MediaTrack] = []
        var subtitleTracks: [MediaTrack] = []
        var selectedAudio: MediaTrack?
        var selectedSubtitle: MediaTrack?
    }

    private let registrar = ObservationRegistrar()

    private var values = Values()

    /// The host's last report of the time: where playback was, when on the
    /// clock, and how fast it was going.
    private var position = 0.0
    private var timestamp: Int64 = 0
    private var advancing: Float = 0

    private let receiver = Receiver()

    private var made: (any MediaPlayback)?

    private var cachedIdentifier: Int32?

    private var nextRequest: Int32 = 1

    private var seeks: [Int32: (Bool) -> Void] = [:]

    #if !EMBEDDED_NO_CONCURRENCY
    private let subscribers = EventSubscribers<MediaEvent, Never>()

    fileprivate var tickers: [MediaTicker] = []
    #endif

    private var playback: any MediaPlayback {
        if let made {
            return made
        }
        receiver.player = Unmanaged.passUnretained(self)
        let playback = MediaPlaybackProxy.make(receiver)
        made = playback
        return playback
    }

    private func mutate(_ index: Int, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: index, change)
    }

    private func emit(_ event: MediaEvent) {
        #if !EMBEDDED_NO_CONCURRENCY
        subscribers.yield(event)
        #endif
    }

    /// Where playback is now, from the last report and the clock.
    fileprivate func timeNow() -> Double {
        guard advancing != 0, let now = try? RuntimeClock.now() else {
            return position
        }
        var time = position + Double(now - timestamp) / 1_000_000_000 * Double(advancing)
        if let duration = values.duration {
            time = min(time, duration)
        }
        return max(time, 0)
    }

    private func describe(_ info: NowPlayingInfo?) {
        guard let info, !info.title.isEmpty else {
            // Nothing made means nothing to take away.
            made?.setNowPlaying("", artist: nil, album: nil)
            return
        }
        playback.setNowPlaying(info.title, artist: info.artist, album: info.album)
        switch info.artwork {
        case .file(let path):
            playback.setArtworkFile(path.directory.rawValue, path: path.path)
        case .data(let bytes, let type):
            playback.setArtworkData(bytes, mimeType: type)
        case nil:
            break
        }
    }

    /// A button is offered when it can be answered.
    private func offerCommands() {
        var commands: MediaRemoteCommands = []
        if onNextTrack != nil {
            commands.insert(.next)
        }
        if onPreviousTrack != nil {
            commands.insert(.previous)
        }
        if skipIntervals != nil {
            commands.insert(.skip)
        }
        guard commands != offered || skipIntervals?.backward != offeredSkip?.backward || skipIntervals?.forward != offeredSkip?.forward else {
            return
        }
        offered = commands
        offeredSkip = skipIntervals
        playback.setRemoteCommands(commands.rawValue, skipBackward: skipIntervals?.backward ?? 0, skipForward: skipIntervals?.forward ?? 0)
    }

    private var offered: MediaRemoteCommands = []

    private var offeredSkip: (backward: Double, forward: Double)?

    // MARK: From the host

    fileprivate func loaded(duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        let size = MediaSize(width: Int(max(width, 0)), height: Int(max(height, 0)))
        mutate(5) { values.duration = duration < 0 ? nil : duration }
        mutate(7) {
            values.videoSize = size
            values.hasAudio = hasAudio
            values.hasVideo = hasVideo
        }
        if values.error != nil {
            mutate(12) { values.error = nil }
        }
        mutate(0) { values.status = .ready }
        emit(.loaded(duration: values.duration, videoSize: size))
    }

    fileprivate func changed(state: Int32, reason: Int32) {
        // A state from a newer host changes nothing here.
        guard let state = MediaState(rawValue: state) else { return }
        func set(playing: Bool, buffering: Bool) {
            if playing != values.isPlaying {
                mutate(1) { values.isPlaying = playing }
            }
            if buffering != values.isBuffering {
                mutate(2) { values.isBuffering = buffering }
            }
        }
        func set(_ status: MediaStatus) {
            if status != values.status {
                mutate(0) { values.status = status }
            }
        }
        switch state {
        case .empty:
            set(playing: false, buffering: false)
            changed(tracks: [], [], selectedAudio: nil, selectedSubtitle: nil)
            mutate(5) { values.duration = nil }
            mutate(7) {
                values.videoSize = .zero
                values.hasAudio = false
                values.hasVideo = false
            }
            position = 0
            advancing = 0
            mutate(4) { }
            set(.empty)
        case .loading:
            set(playing: false, buffering: false)
            if values.error != nil {
                mutate(12) { values.error = nil }
            }
            // Another file: its tracks come once it's loaded.
            changed(tracks: [], [], selectedAudio: nil, selectedSubtitle: nil)
            set(.loading)
        case .paused:
            let reason = MediaPauseReason(rawValue: reason) ?? .requested
            set(playing: false, buffering: false)
            if reason != values.pauseReason {
                mutate(3) { values.pauseReason = reason }
            }
            emit(.paused(reason))
        case .playing:
            set(playing: true, buffering: false)
            emit(.playing)
            #if !EMBEDDED_NO_CONCURRENCY
            for ticker in tickers {
                ticker.start()
            }
            #endif
        case .buffering:
            set(playing: false, buffering: true)
            emit(.buffering)
        case .failed:
            set(playing: false, buffering: false)
            set(.failed)
        }
    }

    fileprivate func changed(position: Double, timestamp: Int64, rate: Float) {
        mutate(4) {
            self.position = position
            self.timestamp = timestamp
            self.advancing = rate
        }
    }

    fileprivate func changed(buffer seconds: Double) {
        guard seconds != values.bufferedTime else { return }
        mutate(6) { values.bufferedTime = seconds }
    }

    fileprivate func seeked(_ request: Int32, finished: Bool) {
        guard let completion = seeks.removeValue(forKey: request) else { return }
        if finished {
            let time = timeNow()
            emit(.seeked(time))
            #if !EMBEDDED_NO_CONCURRENCY
            for ticker in tickers {
                ticker.yield(time)
            }
            #endif
        }
        completion(finished)
    }

    fileprivate func ended() {
        onEnd?()
        emit(.ended)
    }

    fileprivate func failed(_ error: MediaError) {
        mutate(12) { values.error = error }
        if values.status != .failed {
            mutate(0) { values.status = .failed }
        }
        onFailure?(error)
        emit(.failed(error))
    }

    fileprivate func changed(tracks audio: [MediaTrack], _ subtitles: [MediaTrack], selectedAudio: MediaTrack?, selectedSubtitle: MediaTrack?) {
        if audio != values.audioTracks || subtitles != values.subtitleTracks {
            mutate(14) {
                values.audioTracks = audio
                values.subtitleTracks = subtitles
            }
        }
        if selectedAudio != values.selectedAudio {
            mutate(15) { values.selectedAudio = selectedAudio }
        }
        if selectedSubtitle != values.selectedSubtitle {
            mutate(16) { values.selectedSubtitle = selectedSubtitle }
        }
    }

    fileprivate func command(_ command: Int32) {
        switch command {
        case 1:
            onNextTrack?()
            emit(.nextTrack)
        case 2:
            onPreviousTrack?()
            emit(.previousTrack)
        default:
            // A button from a newer host.
            break
        }
    }
}

/// What a cancelled wait for a seek throws, inside the player.
struct MediaSeekCancelled: Error { }

/// The delegate the host holds. It doesn't keep the player alive: the
/// player owns the host's `MediaPlayback`, which owns this, and the player
/// clears the reference when it's released. Embedded Swift has no weak
/// references.
private final class Receiver: MediaPlaybackDelegate {

    var player: Unmanaged<MediaPlayer>?

    private var current: MediaPlayer? {
        player?.takeUnretainedValue()
    }

    func didLoad(_ duration: Double, width: Int32, height: Int32, hasAudio: Bool, hasVideo: Bool) {
        current?.loaded(duration: duration, width: width, height: height, hasAudio: hasAudio, hasVideo: hasVideo)
    }

    func didChangeState(_ state: Int32, reason: Int32) {
        current?.changed(state: state, reason: reason)
    }

    func didChangeTime(_ position: Double, timestamp: Int64, rate: Float) {
        current?.changed(position: position, timestamp: timestamp, rate: rate)
    }

    func didChangeBuffer(_ seconds: Double) {
        current?.changed(buffer: seconds)
    }

    func didSeek(_ request: Int32, finished: Bool) {
        current?.seeked(request, finished: finished)
    }

    func didEnd() {
        current?.ended()
    }

    func didFail(_ code: Int32, message: String) {
        current?.failed(MediaError(MediaError.Code(rawValue: code) ?? .unknown, message: message))
    }

    func didReceiveCommand(_ command: Int32) {
        current?.command(command)
    }

    func didChangeTracks(_ audioNames: [String], audioLanguages: [String], subtitleNames: [String], subtitleLanguages: [String], selectedAudio: Int32, selectedSubtitle: Int32) {
        func tracks(_ names: [String], _ languages: [String]) -> [MediaTrack] {
            var tracks: [MediaTrack] = []
            for index in names.indices {
                let language = index < languages.count ? languages[index] : ""
                tracks.append(MediaTrack(name: names[index], language: language.isEmpty ? nil : language, index: Int32(index)))
            }
            return tracks
        }
        let audio = tracks(audioNames, audioLanguages)
        let subtitles = tracks(subtitleNames, subtitleLanguages)
        func pick(_ tracks: [MediaTrack], _ index: Int32) -> MediaTrack? {
            index >= 0 && Int(index) < tracks.count ? tracks[Int(index)] : nil
        }
        current?.changed(tracks: audio, subtitles, selectedAudio: pick(audio, selectedAudio), selectedSubtitle: pick(subtitles, selectedSubtitle))
    }
}

#if !EMBEDDED_NO_CONCURRENCY
/// One `times(every:)` stream: a timer on the guest's clock that runs while
/// the player plays.
final class MediaTicker {

    private var player: Unmanaged<MediaPlayer>?

    private let interval: Double

    private let continuation: EventStream<Double, Never>.Continuation

    /// Whether a timer is waiting to fire.
    private var isWaiting = false

    init(player: Unmanaged<MediaPlayer>, interval: Double, continuation: EventStream<Double, Never>.Continuation) {
        self.player = player
        self.interval = interval
        self.continuation = continuation
    }

    func yield(_ time: Double) {
        continuation.yield(time)
    }

    /// The player is playing: tick until it isn't.
    func start() {
        guard player != nil, !isWaiting else { return }
        isWaiting = true
        // A host with no clock has no ticks.
        try? RuntimeClock.after(nanoseconds: Int64(interval * 1_000_000_000)) {
            self.isWaiting = false
            guard let player = self.player?.takeUnretainedValue(), player.isPlayingNow else { return }
            self.continuation.yield(player.timeNow())
            self.start()
        }
    }

    /// The stream is finished with, or the player is gone.
    func stop() {
        player = nil
    }
}

extension MediaPlayer {

    /// `isPlaying`, without telling the observation system it was read.
    fileprivate var isPlayingNow: Bool {
        values.isPlaying
    }
}
#endif
