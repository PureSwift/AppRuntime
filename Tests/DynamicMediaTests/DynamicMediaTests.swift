import Testing
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import DynamicSwiftUI
import DynamicUI
import RuntimeCore
import RuntimeNative

/// A host's player that only writes down what it's asked, and keeps its
/// delegate for the test to report through.
final class ScriptedPlayback: MediaPlayback {

    nonisolated(unsafe) static var all: [ScriptedPlayback] = []

    nonisolated(unsafe) static var destroyed: [Int32] = []

    nonisolated(unsafe) static var background = false

    static var last: ScriptedPlayback? { all.last }

    let delegate: any MediaPlaybackDelegate

    let id: Int32

    var calls: [String] = []

    init(delegate: any MediaPlaybackDelegate) {
        self.delegate = delegate
        self.id = Int32(Self.all.count + 1)
    }

    deinit {
        Self.destroyed.append(id)
    }

    static func make(_ delegate: any MediaPlaybackDelegate) -> ScriptedPlayback {
        let playback = ScriptedPlayback(delegate: delegate)
        all.append(playback)
        return playback
    }

    static func canPlay(_ mimeType: String) -> Int32 {
        switch mimeType {
        case "video/mp4": 2
        case "application/vnd.apple.mpegurl": 1
        case "odd/newer": 9
        default: 0
        }
    }

    static func canPlayInBackground() -> Bool { background }

    func identifier() -> Int32 { id }
    func loadURL(_ url: String) { calls.append("loadURL \(url)") }
    func loadFile(_ directory: Int32, path: String) { calls.append("loadFile \(directory) \(path)") }
    func loadData(_ data: [UInt8], mimeType: String) { calls.append("loadData \(data.count) \(mimeType)") }
    func unload() { calls.append("unload") }
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func seek(_ position: Double, request: Int32) { calls.append("seek \(position) \(request)") }
    func setRate(_ rate: Float) { calls.append("setRate \(rate)") }
    func setVolume(_ volume: Float) { calls.append("setVolume \(volume)") }
    func setMuted(_ muted: Bool) { calls.append("setMuted \(muted)") }
    func setLooping(_ looping: Bool) { calls.append("setLooping \(looping)") }
    func setTimeUpdateInterval(_ seconds: Double) { calls.append("setTimeUpdateInterval \(seconds)") }
    func setNowPlaying(_ title: String, artist: String?, album: String?) {
        calls.append("setNowPlaying \(title)|\(artist ?? "-")|\(album ?? "-")")
    }
    func setArtworkFile(_ directory: Int32, path: String) { calls.append("setArtworkFile \(directory) \(path)") }
    func setArtworkData(_ data: [UInt8], mimeType: String) { calls.append("setArtworkData \(data.count) \(mimeType)") }
    func setRemoteCommands(_ commands: Int32, skipBackward: Double, skipForward: Double) {
        calls.append("setRemoteCommands \(commands) \(skipBackward) \(skipForward)")
    }
    func setPlaysInBackground(_ enabled: Bool) { calls.append("setPlaysInBackground \(enabled)") }
    func selectTrack(_ kind: Int32, index: Int32) { calls.append("selectTrack \(kind) \(index)") }

    /// A source that loaded: two minutes, with a picture.
    func load(duration: Double = 120) {
        delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        delegate.didLoad(duration, width: 1280, height: 720, hasAudio: true, hasVideo: true)
        delegate.didChangeState(MediaState.paused.rawValue, reason: 0)
    }
}

/// Records what a view graph sends.
final class MediaSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }
}

struct Screen: View {

    let player: MediaPlayer

    var body: some View {
        VStack {
            VideoPlayer(player, scaling: .fill, controls: .none)
            Text(player.isPlaying ? "Playing" : "Paused")
        }
    }
}

struct Trailer: View {

    let address: () -> String?

    var body: some View {
        VideoPlayer(url: address())
    }
}

final class Listener: AudioPlayerDelegate {
    var finished: [Bool] = []
    var errors: [MediaError] = []
    func audioPlayerDidFinishPlaying(_ player: AudioPlayer, successfully flag: Bool) { finished.append(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AudioPlayer, error: MediaError) { errors.append(error) }
}

/// Serialized: the tests share the native runtime, its clock and the
/// scripted host's list of players, and the frontend keeps the graph being
/// evaluated in a global.
@Suite(.serialized) final class DynamicMediaTests {

    let clock = ManualClock(time: 1_000_000_000)

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        native.runtime.clock = clock
        MediaPlaybackProxy.register(ScriptedPlayback.self, in: native)
        MediaPlaybackDelegateProxy.registerInterface(in: native)
        ScriptedPlayback.all = []
        ScriptedPlayback.destroyed = []
        ScriptedPlayback.background = false
    }

    deinit {
        NativeRuntime.shared.runtime.clock = nil
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    /// A player with a source that has loaded, and its host.
    func loaded() throws -> (MediaPlayer, ScriptedPlayback) {
        let player = MediaPlayer()
        player.load(.url("https://example.com/trailer.mp4"))
        let host = try #require(ScriptedPlayback.last)
        host.load()
        return (player, host)
    }

    // MARK: Contracts

    @Test func playersRequireAudio() {
        let playback = MediaPlaybackProxy.descriptor
        #expect(playback.name == "org.pureswift.media.Playback")
        #expect(playback.capability == .audio)
        #expect(method(playback, "make:")?.kind == .constructor)
        #expect(method(playback, "canPlay:")?.signature == Signature("(O)I"))
        #expect(method(playback, "loadFile:path:")?.signature == Signature("(IO)V"))
        #expect(method(playback, "seek:request:")?.signature == Signature("(DI)V"))
        #expect(method(playback, "setRate:")?.signature == Signature("(F)V"))
        #expect(method(playback, "setNowPlaying:artist:album:")?.signature == Signature("(OOO)V"))
        #expect(method(playback, "setRemoteCommands:skipBackward:skipForward:")?.signature == Signature("(IDD)V"))
        #expect(playback.methods.count == 22, "with choosing a track")

        let delegate = MediaPlaybackDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.media.PlaybackDelegate" && delegate.kind == .callback)
        #expect(method(delegate, "didLoad:width:height:hasAudio:hasVideo:")?.signature == Signature("(DIIZZ)V"))
        #expect(method(delegate, "didChangeTime:timestamp:rate:")?.signature == Signature("(DJF)V"))
        #expect(method(delegate, "didReceiveCommand:")?.signature == Signature("(I)V"))
        let descriptors = [playback, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Sources

    @Test func aPlayerIsMadeInTheHostWhenFirstUsed() throws {
        let player = MediaPlayer()
        #expect(ScriptedPlayback.all.isEmpty)
        #expect(player.status == .empty && !player.isPlaying && player.duration == nil)
        #expect(ScriptedPlayback.all.isEmpty, "reading it makes nothing")

        player.load(.url("https://example.com/a.mp4"))
        let host = try #require(ScriptedPlayback.last)
        player.load(.file(.documents / "songs/one.m4a"))
        player.load(.resource("music/theme.mp3"))
        player.load(.file(FilePath(FileDirectory(rawValue: 300))))
        player.load(.data([1, 2, 3], type: "audio/wav"))
        player.play()
        player.pause()
        player.unload()
        #expect(host.calls == [
            "loadURL https://example.com/a.mp4", "loadFile 0 songs/one.m4a", "loadFile 4 music/theme.mp3",
            "loadFile 300 ", "loadData 3 audio/wav", "play", "pause", "unload",
        ], "the bundle and a picked document are files like any other")
        #expect(ScriptedPlayback.all.count == 1)
        #expect(player.identifier == host.id)
    }

    @Test func aHostSaysWhatItPlays() {
        #expect(MediaPlayer.canPlay("video/mp4") == .probably)
        #expect(MediaPlayer.canPlay("application/vnd.apple.mpegurl") == .maybe)
        #expect(MediaPlayer.canPlay("video/webm") == .no)
        #expect(MediaPlayer.canPlay("odd/newer") == .no, "an answer from a newer host isn't a yes")
        #expect(!MediaPlayer.canPlayInBackground)
        ScriptedPlayback.background = true
        #expect(MediaPlayer.canPlayInBackground)
    }

    // MARK: State

    @Test func thePlayerFollowsWhatTheHostReports() throws {
        let player = MediaPlayer()
        player.load(.url("https://example.com/a.mp4"))
        let host = try #require(ScriptedPlayback.last)
        host.delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        #expect(player.status == .loading)
        host.delegate.didLoad(90.5, width: 1920, height: 1080, hasAudio: true, hasVideo: true)
        #expect(player.status == .ready && player.duration == 90.5)
        #expect(player.videoSize == MediaSize(width: 1920, height: 1080) && player.hasVideo && player.hasAudio)

        host.delegate.didChangeState(MediaState.buffering.rawValue, reason: 0)
        #expect(player.isBuffering && !player.isPlaying)
        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        #expect(player.isPlaying && !player.isBuffering)
        host.delegate.didChangeBuffer(12)
        #expect(player.bufferedTime == 12)
        host.delegate.didChangeState(MediaState.paused.rawValue, reason: MediaPauseReason.user.rawValue)
        #expect(!player.isPlaying && player.pauseReason == .user)
        host.delegate.didChangeState(MediaState.paused.rawValue, reason: 77)
        #expect(player.pauseReason == .requested, "a reason from a newer host")
        host.delegate.didChangeState(99, reason: 0)
        #expect(player.status == .ready, "a state from a newer host changes nothing")

        // A live stream has no duration, and sound alone has no picture.
        host.delegate.didLoad(-1, width: 0, height: 0, hasAudio: true, hasVideo: false)
        #expect(player.duration == nil && player.videoSize == .zero && !player.hasVideo)

        host.delegate.didChangeState(MediaState.empty.rawValue, reason: 0)
        #expect(player.status == .empty && player.currentTime == 0)
    }

    @Test func theTimeIsExactWhenItsRead() throws {
        let (player, host) = try loaded()
        #expect(player.currentTime == 0)
        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        host.delegate.didChangeTime(10, timestamp: clock.now(), rate: 1)
        #expect(player.currentTime == 10)
        clock.advance(by: 2_500_000_000)
        #expect(player.currentTime == 12.5, "worked out from the last report and the clock")
        host.delegate.didChangeTime(13, timestamp: clock.now(), rate: 2)
        clock.advance(by: 1_000_000_000)
        #expect(player.currentTime == 15, "at twice the speed")
        clock.advance(by: 500_000_000_000)
        #expect(player.currentTime == 120, "never past the end")

        host.delegate.didChangeTime(40, timestamp: clock.now(), rate: 0)
        clock.advance(by: 5_000_000_000)
        #expect(player.currentTime == 40, "paused, it stays")

        player.currentTime = 60
        #expect(host.calls.last == "seek 60.0 1", "setting it seeks")
        player.currentTime = -5
        #expect(host.calls.last == "seek 0.0 2")
    }

    @Test func viewsAreToldWhenWhatTheyReadChanges() throws {
        let (player, host) = try loaded()
        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { player.isPlaying } onChange: { changes += 1 }
        host.delegate.didChangeBuffer(3)
        host.delegate.didChangeTime(1, timestamp: clock.now(), rate: 0)
        #expect(changes == 0, "only isPlaying was read")
        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        #expect(changes == 1)

        // The time changes for views at each report, not at each frame.
        _ = withObservationTracking { player.currentTime } onChange: { changes += 1 }
        clock.advance(by: 1_000_000_000)
        #expect(changes == 1)
        host.delegate.didChangeTime(2, timestamp: clock.now(), rate: 1)
        #expect(changes == 2)
    }

    @Test func settingsAreKeptInRangeAndSentOnce() throws {
        let (player, host) = try loaded()
        host.calls = []
        player.rate = 1.5
        player.rate = 9
        player.rate = 0.1
        player.rate = 0.5
        player.volume = 0.25
        player.volume = 2
        player.volume = -1
        player.isMuted = true
        player.isMuted = true
        player.isLooping = true
        player.timeUpdateInterval = 0.1
        player.timeUpdateInterval = 0.1
        #expect(host.calls == [
            "setRate 1.5", "setRate 2.0", "setRate 0.5", "setVolume 0.25", "setVolume 1.0", "setVolume 0.0",
            "setMuted true", "setLooping true", "setTimeUpdateInterval 0.1",
        ])
        #expect(player.rate == 0.5 && player.volume == 0 && player.isMuted && player.isLooping)
    }

    // MARK: Seeking, ending, failing

    @Test func aSeekIsAnsweredOnce() throws {
        let (player, host) = try loaded()
        var answers: [String] = []
        player.seek(to: 30) { answers.append("first \($0)") }
        player.seek(to: 45) { answers.append("second \($0)") }
        #expect(host.calls.suffix(2) == ["seek 30.0 1", "seek 45.0 2"])
        host.delegate.didSeek(1, finished: false)
        host.delegate.didChangeTime(45, timestamp: clock.now(), rate: 0)
        host.delegate.didSeek(2, finished: true)
        host.delegate.didSeek(2, finished: true)
        host.delegate.didSeek(44, finished: true)
        #expect(answers == ["first false", "second true"], "another seek replaced the first")
        #expect(player.currentTime == 45)
    }

    @Test func theEndAndAFailureCallTheirClosures() throws {
        let (player, host) = try loaded()
        var ended = 0
        var failures: [MediaError] = []
        player.onEnd = { ended += 1 }
        player.onFailure = { failures.append($0) }
        host.delegate.didChangeState(MediaState.paused.rawValue, reason: MediaPauseReason.ended.rawValue)
        host.delegate.didEnd()
        #expect(ended == 1 && player.pauseReason == .ended)

        host.delegate.didChangeState(MediaState.failed.rawValue, reason: 0)
        host.delegate.didFail(MediaError.Code.network.rawValue, message: "connection lost")
        #expect(player.status == .failed)
        #expect(player.error == MediaError(.network, message: "connection lost"))
        #expect(failures == [MediaError(.network, message: "connection lost")])
        host.delegate.didFail(123, message: "odd")
        #expect(player.error?.code == .unknown, "a code from a newer host")

        // Another source clears the error once it starts to load.
        host.delegate.didChangeState(MediaState.loading.rawValue, reason: 0)
        #expect(player.error == nil && player.status == .loading)
    }

    @Test func releasingThePlayerDestroysTheHosts() throws {
        var player: MediaPlayer? = MediaPlayer()
        player?.load(.resource("a.mp3"))
        let id = try #require(ScriptedPlayback.last).id
        ScriptedPlayback.all = []
        #expect(ScriptedPlayback.destroyed.isEmpty)
        player = nil
        #expect(ScriptedPlayback.destroyed == [id])
    }

    // MARK: Now playing

    @Test func whatsPlayingIsSaidToTheHost() throws {
        let (player, host) = try loaded()
        host.calls = []
        player.nowPlaying = NowPlayingInfo(title: "So What", artist: "Miles Davis", album: "Kind of Blue",
                                           artwork: .file(.caches / "covers/kob.jpg"))
        #expect(host.calls == ["setNowPlaying So What|Miles Davis|Kind of Blue", "setArtworkFile 2 covers/kob.jpg"])
        player.nowPlaying = NowPlayingInfo(title: "So What", artist: "Miles Davis", album: "Kind of Blue",
                                           artwork: .file(.caches / "covers/kob.jpg"))
        #expect(host.calls.count == 2, "said once")

        player.nowPlaying = NowPlayingInfo(title: "Episode 12", artwork: .data([1, 2, 3, 4], type: "image/png"))
        #expect(host.calls.suffix(2) == ["setNowPlaying Episode 12|-|-", "setArtworkData 4 image/png"])
        player.nowPlaying = NowPlayingInfo(title: "No picture")
        #expect(host.calls.last == "setNowPlaying No picture|-|-")

        player.nowPlaying = nil
        #expect(host.calls.last == "setNowPlaying |-|-", "an empty title takes it away")
        player.nowPlaying = NowPlayingInfo(title: "Back")
        player.unload()
        #expect(player.nowPlaying == nil && host.calls.suffix(2) == ["unload", "setNowPlaying |-|-"], "unloading takes it away too")
    }

    @Test func aButtonIsOfferedWhenItCanBeAnswered() throws {
        let (player, host) = try loaded()
        host.calls = []
        var pressed: [String] = []
        player.onNextTrack = { pressed.append("next") }
        #expect(host.calls == ["setRemoteCommands 1 0.0 0.0"])
        player.onPreviousTrack = { pressed.append("previous") }
        #expect(host.calls.last == "setRemoteCommands 3 0.0 0.0")
        player.skipIntervals = (backward: 15, forward: 30)
        #expect(host.calls.last == "setRemoteCommands 7 15.0 30.0")
        player.skipIntervals = (backward: 15, forward: 30)
        #expect(host.calls.count == 3, "said once")
        player.onNextTrack = nil
        #expect(host.calls.last == "setRemoteCommands 6 15.0 30.0")

        host.delegate.didReceiveCommand(2)
        host.delegate.didReceiveCommand(1)
        host.delegate.didReceiveCommand(9)
        #expect(pressed == ["previous"], "next isn't answered any more; a newer button is nothing")

        player.playsInBackground = true
        player.playsInBackground = true
        player.playsInBackground = false
        #expect(host.calls.suffix(2) == ["setPlaysInBackground true", "setPlaysInBackground false"])
    }

    // MARK: Views

    @Test func theNodeNamesThePlayer() throws {
        let (player, host) = try loaded()
        let sink = MediaSink()
        let graph = ViewGraph(Screen(player: player), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.first("VideoPlayer"))
        #expect(node.props["player"] == .int(Int(host.id)))
        #expect(node.props["scaling"] == "fill" && node.props["controls"] == "none")
        #expect(sink.screen?.first("Text")?.props["text"] == "Paused")

        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        graph.update()
        #expect(sink.screen?.first("Text")?.props["text"] == "Playing")
        #expect(sink.screen?.first("VideoPlayer")?.id == node.id, "the same node: the host keeps its picture")
    }

    @Test func aURLViewKeepsItsOwnPlayer() throws {
        nonisolated(unsafe) var address: String? = "https://example.com/a.mp4"
        let sink = MediaSink()
        let graph = ViewGraph(Trailer(address: { address }), sink: sink)
        graph.update()
        let host = try #require(ScriptedPlayback.last)
        #expect(host.calls == ["loadURL https://example.com/a.mp4"])
        let node = try #require(sink.screen?.first("VideoPlayer"))
        #expect(node.props["player"] == .int(Int(host.id)))
        #expect(node.props["scaling"] == "fit" && node.props["controls"] == "platform")

        graph.setNeedsUpdate()
        graph.update()
        #expect(host.calls.count == 1, "the same URL isn't loaded again")
        address = "https://example.com/b.mp4"
        graph.setNeedsUpdate()
        graph.update()
        #expect(host.calls.last == "loadURL https://example.com/b.mp4")
        address = nil
        graph.setNeedsUpdate()
        graph.update()
        #expect(host.calls.last == "unload")
        #expect(ScriptedPlayback.all.count == 1)
    }

    // MARK: Audio

    @Test func anAudioPlayerHasAVAudioPlayersShape() throws {
        let listener = Listener()
        let player = AudioPlayer(.resource("music/theme.mp3"))
        player.delegate = listener
        let host = try #require(ScriptedPlayback.last)
        #expect(host.calls == ["loadFile 4 music/theme.mp3"], "loading starts when it's made")
        #expect(!player.isReady && player.duration == 0, "not known until it's loaded")
        host.load(duration: 3)
        #expect(player.isReady && player.duration == 3)

        #expect(player.prepareToPlay() && player.play())
        player.volume = 0.8
        player.rate = 1.25
        player.currentTime = 1
        player.pause()
        player.stop()
        #expect(host.calls.suffix(7) == ["play", "setVolume 0.8", "setRate 1.25", "seek 1.0 1", "pause", "pause", "seek 0.0 2"],
                "stopping pauses, and goes back to the start")
        #expect(player.volume == 0.8 && player.rate == 1.25)

        // Twice more after the first, then it's finished.
        player.numberOfLoops = 2
        host.calls = []
        host.delegate.didEnd()
        host.delegate.didEnd()
        #expect(host.calls == ["seek 0.0 3", "play", "seek 0.0 4", "play"] && listener.finished.isEmpty)
        host.delegate.didEnd()
        #expect(listener.finished == [true])

        player.numberOfLoops = -1
        #expect(host.calls.last == "setLooping true", "for ever is the host's to loop")
        player.numberOfLoops = 0
        #expect(host.calls.last == "setLooping false")

        host.delegate.didChangeState(MediaState.failed.rawValue, reason: 0)
        host.delegate.didFail(MediaError.Code.unsupportedFormat.rawValue, message: "")
        #expect(listener.errors == [MediaError(.unsupportedFormat)])
        #expect(!player.play() && !player.prepareToPlay(), "nothing to play")
    }

    @Test func releasingAnAudioPlayerReleasesItsPlayer() throws {
        var player: AudioPlayer? = AudioPlayer(.resource("a.wav"))
        let id = try #require(ScriptedPlayback.last).id
        ScriptedPlayback.all = []
        #expect(player != nil)
        player = nil
        #expect(ScriptedPlayback.destroyed == [id], "its closures don't keep it alive")
    }

    // MARK: Async

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded (§6.4), and so is the native runtime.

    @MainActor @Test func eventsReachEveryStreamInOrder() async throws {
        let (player, host) = try loaded()
        var calls: [String] = []
        player.onEnd = { calls.append("onEnd") }
        player.onNextTrack = { calls.append("onNext") }
        func collect(_ count: Int) -> Task<[MediaEvent], Never> {
            Task { @MainActor in
                var events: [MediaEvent] = []
                for await event in player.events {
                    events.append(event)
                    if case .ended = event { calls.append("ended event") }
                    if events.count == count { break }
                }
                return events
            }
        }
        let first = collect(8)
        let second = collect(2)
        // Both are listening once their tasks have run.
        for _ in 0..<10 { await Task.yield() }

        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        host.delegate.didChangeState(MediaState.buffering.rawValue, reason: 0)
        host.delegate.didChangeState(MediaState.paused.rawValue, reason: MediaPauseReason.interrupted.rawValue)
        player.seek(to: 20) { _ in }
        host.delegate.didChangeTime(20, timestamp: clock.now(), rate: 0)
        host.delegate.didSeek(1, finished: true)
        host.delegate.didReceiveCommand(1)
        host.delegate.didEnd()
        host.delegate.didLoad(-1, width: 0, height: 0, hasAudio: true, hasVideo: false)
        host.delegate.didFail(MediaError.Code.decoding.rawValue, message: "bad")

        #expect(await second.value == [.playing, .buffering])
        #expect(await first.value == [
            .playing, .buffering, .paused(.interrupted), .seeked(20), .nextTrack, .ended,
            .loaded(duration: nil, videoSize: .zero), .failed(MediaError(.decoding, message: "bad")),
        ])
        #expect(calls == ["onNext", "onEnd", "ended event"], "the closures are called before the stream's event")
    }

    @MainActor @Test func aSeekCanBeAwaited() async throws {
        let (player, host) = try loaded()
        let seeking = Task { @MainActor in
            await player.seek(to: 50)
        }
        while !host.calls.contains("seek 50.0 1") {
            await Task.yield()
        }
        host.delegate.didSeek(1, finished: true)
        #expect(await seeking.value)

        let replaced = Task { @MainActor in
            await player.seek(to: 60)
        }
        while !host.calls.contains("seek 60.0 2") {
            await Task.yield()
        }
        host.delegate.didSeek(2, finished: false)
        #expect(await replaced.value == false)
    }

    @MainActor @Test func timesTickWhileItPlays() async throws {
        let (player, host) = try loaded()
        let ticking = Task { @MainActor in
            var times: [Double] = []
            for await time in player.times(every: 0.5) {
                times.append(time)
                if times.count == 4 { break }
            }
            return times
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(clock.pendingCount == 0, "nothing ticks while it's paused")

        host.delegate.didChangeTime(0, timestamp: clock.now(), rate: 1)
        host.delegate.didChangeState(MediaState.playing.rawValue, reason: 0)
        clock.advance(by: 500_000_000)
        clock.advance(by: 500_000_000)
        // A seek is reported at once.
        player.seek(to: 30) { _ in }
        host.delegate.didChangeTime(30, timestamp: clock.now(), rate: 1)
        host.delegate.didSeek(1, finished: true)
        clock.advance(by: 500_000_000)
        #expect(await ticking.value == [0.5, 1, 30, 30.5])

        // Paused, the next tick finds nothing to say and stops.
        host.delegate.didChangeState(MediaState.paused.rawValue, reason: 0)
        clock.advance(by: 5_000_000_000)
        #expect(clock.pendingCount == 0)
    }
}
