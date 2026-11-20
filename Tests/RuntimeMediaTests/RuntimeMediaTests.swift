import Foundation
import Testing
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeMedia

/// One of the platform's players, kept in memory: it does what it's told
/// at once, and the test says when a source has loaded.
final class TestEngine: MediaEngine {

    weak var player: HostMediaPlayback?

    var calls: [String] = []

    var source: HostMediaSource?

    var currentTime = 0.0

    var isPlaying = false

    /// A seek the test will finish itself.
    var holdsSeeks = false

    var heldSeeks: [(position: Double, completion: (Bool) -> Void)] = []

    init(player: HostMediaPlayback) {
        self.player = player
    }

    func load(_ source: HostMediaSource) {
        calls.append("load")
        self.source = source
        currentTime = 0
        isPlaying = false
    }

    func unload() {
        calls.append("unload")
        source = nil
        isPlaying = false
    }

    func play() {
        calls.append("play")
        isPlaying = true
        player?.stateChanged(.playing)
        player?.timeChanged(position: currentTime, rate: 1)
    }

    func pause() {
        calls.append("pause")
        isPlaying = false
        player?.stateChanged(.paused)
        player?.timeChanged(position: currentTime, rate: 0)
    }

    func seek(to position: Double, completion: @escaping (Bool) -> Void) {
        calls.append("seek \(position)")
        if holdsSeeks {
            heldSeeks.append((position, completion))
        } else {
            currentTime = position
            completion(true)
        }
    }

    func setRate(_ rate: Float) { calls.append("setRate \(rate)") }
    func setVolume(_ volume: Float) { calls.append("setVolume \(volume)") }
    func setMuted(_ muted: Bool) { calls.append("setMuted \(muted)") }
    func setLooping(_ looping: Bool) { calls.append("setLooping \(looping)") }
    func setTimeUpdateInterval(_ seconds: Double) { calls.append("setTimeUpdateInterval \(seconds)") }

    /// The source turned out to be playable.
    func finishLoading(duration: Double? = 200) {
        player?.loaded(duration: duration, width: 0, height: 0, hasAudio: true, hasVideo: false)
    }
}

final class TestPlatform: MediaPlatform {

    var engines: [TestEngine] = []

    /// What it was last told to show as playing; `nil` once it's told to
    /// show nothing.
    var shown: HostNowPlaying?

    var updates = 0

    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        let engine = TestEngine(player: player)
        engines.append(engine)
        return engine
    }

    func canPlay(_ mimeType: String) -> MediaSupport {
        mimeType == "audio/mpeg" ? .probably : .no
    }

    func showNowPlaying(_ nowPlaying: HostNowPlaying?) {
        shown = nowPlaying
        updates += 1
    }
}

/// A platform with nowhere to show what's playing: the default.
final class QuietPlatform: MediaPlatform {
    var engine: TestEngine?
    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        let engine = TestEngine(player: player)
        self.engine = engine
        return engine
    }
    func canPlay(_ mimeType: String) -> MediaSupport { .maybe }
}

/// `HostMediaPlayback` over a test's players and real files, driven from
/// the guest's `MediaPlayer` through the runtime.
///
/// Serialized: `HostMediaPlayback`, `HostFiles` and the native runtime are
/// shared.
@Suite(.serialized) final class RuntimeMediaTests {

    let platform = TestPlatform()

    let clock = ManualClock(time: 5_000_000_000)

    let root: URL

    init() throws {
        let manager = Foundation.FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent("RuntimeMediaTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try manager.createDirectory(at: root.appendingPathComponent("Container/Documents/songs"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Home"), withIntermediateDirectories: true)
        try Data("a song".utf8).write(to: root.appendingPathComponent("Container/Documents/songs/one.m4a"))
        try Data("a cover".utf8).write(to: root.appendingPathComponent("Container/Documents/cover.jpg"))
        try Data("the user's song".utf8).write(to: root.appendingPathComponent("Home/picked.mp3"))

        let native = NativeRuntime.shared
        native.capabilities = nil
        native.runtime.clock = clock
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Container/Documents").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostMediaPlayback.reset()
        HostMediaPlayback.platform = platform
        HostMediaPlayback.clock = clock
        HostMediaPlayback.allowsNetwork = true
        HostMediaModule.register(in: native)
    }

    deinit {
        HostMediaPlayback.reset()
        NativeRuntime.shared.runtime.clock = nil
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    /// A player with a song loaded, and its engine.
    func loaded(_ player: MediaPlayer = MediaPlayer()) throws -> (MediaPlayer, TestEngine) {
        player.load(.file(.documents / "songs/one.m4a"))
        let engine = try #require(platform.engines.last)
        engine.finishLoading()
        return (player, engine)
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostMediaModule.contracts.map(\.name) == ["org.pureswift.media.Playback", "org.pureswift.media.PlaybackDelegate"])
        #expect(HostMediaModule.permissionProviders()[.audio]?.status() == .granted, "nothing asks before an app plays sound")
        #expect(MediaPlayer.canPlay("audio/mpeg") == .probably && MediaPlayer.canPlay("video/webm") == .no)
        HostMediaPlayback.platform = nil
        #expect(MediaPlayer.canPlay("audio/mpeg") == .no)
    }

    // MARK: Sources

    @Test func aFileIsFoundBeforeTheEngineSeesIt() throws {
        let player = MediaPlayer()
        var failures: [MediaError.Code] = []
        player.onFailure = { failures.append($0.code) }
        player.load(.file(.documents / "songs/one.m4a"))
        let engine = try #require(platform.engines.last)
        #expect(engine.source == .file(path: root.appendingPathComponent("Container/Documents/songs/one.m4a").path))
        #expect(player.status == .loading)
        engine.finishLoading(duration: 180)
        #expect(player.status == .ready && player.duration == 180 && !player.isPlaying)
        #expect(player.pauseReason == .requested, "paused at its start")

        player.load(.file(.documents / "songs/none.m4a"))
        #expect(player.status == .failed && player.error?.code == .notFound)
        player.load(.file(.documents / "songs"))
        #expect(failures == [.notFound, .notFound], "a folder isn't a song")
        player.load(.file(.documents / "../Home/picked.mp3"))
        #expect(failures.last == .notFound, "a path that leaves its directory")
        #expect(engine.calls.filter { $0 == "load" }.count == 1, "none of those reached the engine")

        // A document the user picked is a directory like the app's own.
        let granted = HostFiles.grant(HostFiles.Grant(path: root.appendingPathComponent("Home/picked.mp3").path, kind: .file, isWritable: false))
        player.load(.file(FilePath(granted)))
        #expect(engine.source == .file(path: root.appendingPathComponent("Home/picked.mp3").path))
        HostFiles.revoke(granted)
        player.load(.file(FilePath(granted)))
        #expect(failures.last == .notPermitted, "a document the app no longer holds")

        player.load(.data([1, 2, 3], type: "audio/wav"))
        #expect(engine.source == .data([1, 2, 3], mimeType: "audio/wav"))
        player.load(.data([], type: "audio/wav"))
        #expect(failures.last == .decoding)
    }

    @Test func aURLNeedsTheNetworkAndAScheme() throws {
        let player = MediaPlayer()
        player.load(.url("HTTPS://example.com/a.mp4"))
        let engine = try #require(platform.engines.last)
        #expect(engine.source == .url("HTTPS://example.com/a.mp4"))
        player.load(.url("file:///etc/passwd"))
        #expect(player.error?.code == .notPermitted)
        player.load(.url("rtsp://example.com/stream"))
        #expect(player.error?.code == .notPermitted)
        HostMediaPlayback.allowsNetwork = false
        player.load(.url("https://example.com/a.mp4"))
        #expect(player.status == .failed && player.error?.code == .notPermitted, "the manifest doesn't declare network")
        #expect(engine.calls.filter { $0 == "load" }.count == 1)
    }

    @Test func aHostWithNoPlayersSaysSo() {
        HostMediaPlayback.platform = nil
        let player = MediaPlayer()
        player.load(.file(.documents / "songs/one.m4a"))
        #expect(player.status == .failed && player.error?.code == .unavailable)
        player.play()
        var answer: Bool?
        player.seek(to: 5) { answer = $0 }
        #expect(answer == false && !player.isPlaying)
        #expect(!MediaPlayer.canPlayInBackground)
    }

    // MARK: Playing

    @Test func playBeforeItsReadyIsRemembered() throws {
        let player = MediaPlayer()
        player.play()
        player.load(.file(.documents / "songs/one.m4a"))
        let engine = try #require(platform.engines.last)
        #expect(!engine.calls.contains("play") && !player.isPlaying)
        engine.finishLoading()
        #expect(engine.calls.last == "play" && player.isPlaying, "it starts when it can")

        // Pausing first takes that back.
        player.load(.file(.documents / "songs/one.m4a"))
        player.play()
        player.pause()
        engine.finishLoading()
        #expect(!player.isPlaying)
    }

    @Test func theTimeIsOnTheGuestsClock() throws {
        let (player, engine) = try loaded()
        engine.currentTime = 30
        player.play()
        #expect(player.currentTime == 30)
        clock.advance(by: 4_000_000_000)
        #expect(player.currentTime == 34, "from the report's timestamp, which is the guest's clock's")
        player.pause()
        clock.advance(by: 4_000_000_000)
        #expect(player.currentTime == 30, "the engine said where it stopped")
    }

    @Test func aSeekIsAnsweredOnceAndTheLastOneWins() throws {
        let (player, engine) = try loaded()
        var answers: [String] = []
        player.seek(to: 40) { answers.append("a \($0)") }
        #expect(answers == ["a true"] && player.currentTime == 40)

        engine.holdsSeeks = true
        player.seek(to: 50) { answers.append("b \($0)") }
        player.seek(to: 60) { answers.append("c \($0)") }
        #expect(answers == ["a true", "b false"], "replaced before it landed")
        engine.currentTime = 60
        engine.heldSeeks[0].completion(true)
        #expect(answers.count == 2, "the first seek's late answer is nobody's")
        engine.heldSeeks[1].completion(true)
        #expect(answers == ["a true", "b false", "c true"] && player.currentTime == 60)

        // A new source drops a seek that hasn't landed.
        player.seek(to: 70) { answers.append("d \($0)") }
        player.load(.file(.documents / "songs/one.m4a"))
        #expect(answers.last == "d false")
        player.unload()
        player.seek(to: 5) { answers.append("e \($0)") }
        #expect(answers.last == "e false", "nothing to seek in")
        #expect(player.status == .empty)
    }

    @Test func theEndIsAPauseAndThenTheEnd() throws {
        let (player, engine) = try loaded()
        var order: [String] = []
        player.onEnd = { order.append("ended while \(player.isPlaying ? "playing" : "paused") for \(player.pauseReason)") }
        player.play()
        engine.player?.ended()
        #expect(order == ["ended while paused for ended"])
        engine.player?.failed(MediaError(.decoding, message: "damaged"))
        #expect(player.status == .failed && player.error == MediaError(.decoding, message: "damaged"))
    }

    // MARK: The background, interruptions, headphones

    @Test func leavingTheFrontPausesAPlayerThatDoesntPlayOn() throws {
        let (player, engine) = try loaded()
        player.play()
        HostMediaPlayback.applicationDidEnterBackground()
        #expect(!player.isPlaying && player.pauseReason == .background)
        #expect(engine.calls.last == "pause")
        #expect(!HostMediaPlayback.holdsApp)

        // Without the manifest's leave, asking changes nothing.
        player.playsInBackground = true
        player.play()
        HostMediaPlayback.applicationDidEnterBackground()
        #expect(!player.isPlaying && !MediaPlayer.canPlayInBackground)
    }

    @Test func aPlayerThatPlaysOnHoldsTheApp() throws {
        HostMediaPlayback.allowsBackground = true
        #expect(MediaPlayer.canPlayInBackground)
        let (music, _) = try loaded()
        let (effect, _) = try loaded()
        music.playsInBackground = true
        music.play()
        effect.play()
        HostMediaPlayback.applicationDidEnterBackground()
        #expect(music.isPlaying && !effect.isPlaying, "only the one that asked plays on")
        #expect(effect.pauseReason == .background)
        #expect(HostMediaPlayback.holdsApp, "as a background activity does")
        music.pause()
        #expect(!HostMediaPlayback.holdsApp, "a paused player holds nothing")
    }

    @Test func anInterruptionPausesAndMayResume() throws {
        let (playing, _) = try loaded()
        let (idle, _) = try loaded()
        playing.play()
        HostMediaPlayback.interruptionBegan()
        #expect(!playing.isPlaying && playing.pauseReason == .interrupted)
        #expect(idle.pauseReason == .requested, "what wasn't playing wasn't interrupted")
        HostMediaPlayback.interruptionEnded(shouldResume: true)
        #expect(playing.isPlaying && !idle.isPlaying, "what it paused plays again")

        HostMediaPlayback.interruptionBegan()
        HostMediaPlayback.interruptionEnded(shouldResume: false)
        #expect(!playing.isPlaying, "only when the system says so")

        playing.play()
        HostMediaPlayback.outputRouteWasLost()
        #expect(!playing.isPlaying && playing.pauseReason == .routeChanged)
    }

    // MARK: Now playing

    @Test func whatsPlayingIsShownWithWhatTheHostKnows() throws {
        let (player, engine) = try loaded()
        #expect(platform.shown == nil && platform.updates == 0, "nothing until the app says what it is")
        player.nowPlaying = NowPlayingInfo(title: "So What", artist: "Miles Davis", album: "Kind of Blue",
                                           artwork: .file(.documents / "cover.jpg"))
        #expect(platform.shown == HostNowPlaying(
            player: player.identifier, title: "So What", artist: "Miles Davis", album: "Kind of Blue",
            artwork: .file(path: root.appendingPathComponent("Container/Documents/cover.jpg").path),
            commands: [], skipBackward: 0, skipForward: 0, position: 0, duration: 200, rate: 0, isPlaying: false
        ))

        engine.currentTime = 12
        player.rate = 1.5
        player.play()
        #expect(platform.shown?.isPlaying == true && platform.shown?.position == 12 && platform.shown?.rate == 1.5)
        let updates = platform.updates
        engine.player?.timeChanged(position: 13, rate: 1.5)
        engine.player?.bufferChanged(4)
        #expect(platform.updates == updates, "at each change of state, not on a timer")
        player.pause()
        #expect(platform.shown?.isPlaying == false && platform.shown?.rate == 0)

        // A picture that isn't there is no picture; bytes are as good as a file.
        player.nowPlaying = NowPlayingInfo(title: "Next", artwork: .file(.documents / "none.jpg"))
        #expect(platform.shown?.title == "Next" && platform.shown?.artwork == nil && platform.shown?.artist == nil)
        player.nowPlaying = NowPlayingInfo(title: "Tagged", artwork: .data([9, 8, 7], type: "image/png"))
        #expect(platform.shown?.artwork == .data([9, 8, 7], mimeType: "image/png"))

        player.nowPlaying = nil
        #expect(platform.shown == nil)
        player.nowPlaying = NowPlayingInfo(title: "Back")
        player.unload()
        #expect(platform.shown == nil, "nothing is shown for a player with no source")
    }

    @Test func thePlayerLastDescribedIsTheOneShown() throws {
        let (first, _) = try loaded()
        var second: MediaPlayer? = try loaded().0
        first.nowPlaying = NowPlayingInfo(title: "First")
        second?.nowPlaying = NowPlayingInfo(title: "Second")
        #expect(platform.shown?.title == "Second" && platform.shown?.player == second?.identifier)
        first.play()
        #expect(platform.shown?.title == "Second" && platform.shown?.isPlaying == false, "the other player's doings don't show")
        second = nil
        #expect(platform.shown == nil, "releasing the player ends all of it")
    }

    @Test func theHostAnswersTheButtonsItCan() throws {
        #expect(!HostMediaPlayback.remote(.play), "nothing is playing to answer")
        let (player, engine) = try loaded()
        #expect(!HostMediaPlayback.remote(.play), "the app hasn't said what's playing")
        player.nowPlaying = NowPlayingInfo(title: "Episode 12")

        #expect(HostMediaPlayback.remote(.play))
        #expect(player.isPlaying)
        #expect(HostMediaPlayback.remote(.pause))
        #expect(!player.isPlaying && player.pauseReason == .user, "the user did, not the app")
        #expect(HostMediaPlayback.remote(.togglePlayPause) && player.isPlaying)
        #expect(HostMediaPlayback.remote(.togglePlayPause) && !player.isPlaying && player.pauseReason == .user)
        player.play()
        player.pause()
        #expect(player.pauseReason == .requested, "and this time the app did")

        #expect(HostMediaPlayback.remote(.seek(to: 90)))
        #expect(player.currentTime == 90 && platform.shown?.position == 90)
        #expect(HostMediaPlayback.remote(.seek(to: 999)) && player.currentTime == 200, "not past the end")

        // Skipping is offered when the app gave intervals.
        engine.currentTime = 100
        #expect(!HostMediaPlayback.remote(.skipForward))
        player.skipIntervals = (backward: 15, forward: 30)
        #expect(platform.shown?.commands == .skip && platform.shown?.skipForward == 30)
        #expect(HostMediaPlayback.remote(.skipForward) && player.currentTime == 130)
        #expect(HostMediaPlayback.remote(.skipBackward) && player.currentTime == 115)
        engine.currentTime = 5
        #expect(HostMediaPlayback.remote(.skipBackward) && player.currentTime == 0, "not before the start")
    }

    @Test func nextAndPreviousGoToTheApp() throws {
        let (player, _) = try loaded()
        player.nowPlaying = NowPlayingInfo(title: "Track 1")
        var pressed: [String] = []
        #expect(!HostMediaPlayback.remote(.next), "not offered: the app can't answer it")
        player.onNextTrack = { pressed.append("next") }
        #expect(platform.shown?.commands == .next)
        #expect(HostMediaPlayback.remote(.next) && pressed == ["next"])
        #expect(!HostMediaPlayback.remote(.previous))
        player.onPreviousTrack = { pressed.append("previous") }
        #expect(platform.shown?.commands == [.next, .previous])
        #expect(HostMediaPlayback.remote(.previous) && pressed == ["next", "previous"])
    }

    // MARK: Showing

    @Test func aViewsNodeFindsThePlayersEngine() throws {
        let (player, engine) = try loaded()
        let identifier = player.identifier
        #expect(HostMediaPlayback.player(for: identifier)?.engine === engine)
        #expect(HostMediaPlayback.player(for: identifier)?.state == .paused)
        #expect(HostMediaPlayback.player(for: 9999) == nil)
    }

    @Test func releasingThePlayerUnloadsTheEngine() throws {
        var player: MediaPlayer? = MediaPlayer()
        player?.load(.file(.documents / "songs/one.m4a"))
        let engine = try #require(platform.engines.last)
        let identifier = try #require(player?.identifier)
        player = nil
        #expect(engine.calls.last == "unload")
        #expect(HostMediaPlayback.player(for: identifier) == nil)
    }

    @Test func aPlatformWithNowhereToShowItStillPlays() throws {
        let quiet = QuietPlatform()
        HostMediaPlayback.platform = quiet
        let player = MediaPlayer()
        player.load(.file(.documents / "songs/one.m4a"))
        quiet.engine?.finishLoading()
        player.nowPlaying = NowPlayingInfo(title: "Unseen")
        player.play()
        #expect(player.isPlaying && HostMediaPlayback.remote(.pause) && !player.isPlaying)
    }
}
