import Foundation
import Testing
import DynamicFiles
import DynamicMedia
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeHost
import RuntimeMedia
import RuntimeNative
import RuntimeWasm

/// One of the platform's players, kept in memory: it does what it's told
/// at once, and the test says when a source has loaded.
final class WasmTestEngine: MediaEngine {

    weak var player: HostMediaPlayback?

    var source: HostMediaSource?

    var currentTime = 0.0

    init(player: HostMediaPlayback) {
        self.player = player
    }

    func load(_ source: HostMediaSource) {
        self.source = source
        currentTime = 0
    }

    func unload() {
        source = nil
    }

    func play() {
        player?.stateChanged(.playing)
        player?.timeChanged(position: currentTime, rate: 1)
    }

    func pause() {
        player?.stateChanged(.paused)
        player?.timeChanged(position: currentTime, rate: 0)
    }

    func seek(to position: Double, completion: @escaping (Bool) -> Void) {
        currentTime = position
        completion(true)
    }

    func setRate(_ rate: Float) { }
    func setVolume(_ volume: Float) { }
    func setMuted(_ muted: Bool) { }
    func setLooping(_ looping: Bool) { }
    func setTimeUpdateInterval(_ seconds: Double) { }

    /// The source turned out to be a three-minute song.
    func finishLoading() {
        player?.loaded(duration: 180, width: 0, height: 0, hasAudio: true, hasVideo: false)
    }
}

final class WasmTestPlatform: MediaPlatform {

    var engines: [WasmTestEngine] = []

    /// What the system was last told to show as playing.
    var shown: HostNowPlaying?

    func makeEngine(for player: HostMediaPlayback) -> any MediaEngine {
        let engine = WasmTestEngine(player: player)
        engines.append(engine)
        return engine
    }

    func canPlay(_ mimeType: String) -> MediaSupport { .probably }

    func showNowPlaying(_ nowPlaying: HostNowPlaying?) {
        shown = nowPlaying
    }
}

/// The first node of a type in a tree.
private func mediaNode(_ type: String, in node: RenderNode?) -> RenderNode? {
    guard let node else { return nil }
    if node.type == type { return node }
    for child in node.children {
        if let found = mediaNode(type, in: child) { return found }
    }
    return nil
}

/// The example media app as App.wasm under WasmKit, with the shared host
/// implementation over players the test keeps in memory: the guest's
/// `MediaPlayer` and `VideoPlayer`, the `MediaPlayback` contract and
/// `HostMediaPlayback`, end to end, with files found through `HostFiles`.
/// Part of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleMedia`; skipped without it.
    static var exampleMediaURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleMedia/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleMediaURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleMedia"))
    func exampleMediaInWasmMode() throws {
        let native = NativeRuntime.shared
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleMedia-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        // The app's bundle: three songs and their cover.
        let music = root.appendingPathComponent("App/resources/music")
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        for name in ["morning.mp3", "noon.mp3", "night.mp3", "cover.png"] {
            try Data(name.utf8).write(to: music.appendingPathComponent(name))
        }

        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .bundle: root.appendingPathComponent("App/resources").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let platform = WasmTestPlatform()
        HostMediaPlayback.reset()
        HostMediaPlayback.platform = platform
        HostMediaPlayback.allowsNetwork = true
        HostMediaPlayback.allowsBackground = true
        HostMediaModule.register(in: native)
        defer { HostMediaPlayback.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleMediaURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.audio])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.media.Playback" }?.capability == .audio)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func song(_ name: String) -> HostMediaSource {
            .file(path: music.appendingPathComponent(name).path)
        }

        // The app loaded its first song from the bundle, and said what it is.
        let player = try #require(platform.engines.first)
        #expect(player.source == song("morning.mp3"))
        #expect(text("title") == "Morning, The Examples" && text("state") == "Paused")
        #expect(text("status") == "Plays in the background", "the manifest allows it")
        var shown = try #require(platform.shown)
        #expect(shown.title == "Morning" && shown.artist == "The Examples" && shown.album == "Examples")
        #expect(shown.artwork == .file(path: music.appendingPathComponent("cover.png").path))
        #expect(shown.commands == [.next, .previous, .skip] && shown.skipBackward == 10 && shown.skipForward == 10)
        #expect(!shown.isPlaying && shown.duration == nil, "not loaded yet")
        player.finishLoading()
        #expect(platform.shown?.duration == 180, "the host adds what it knows of the player")

        try tap("Play")
        #expect(text("state") == "Playing" && renderer.screen?.button("Pause") != nil)
        #expect(platform.shown?.isPlaying == true)

        // The system's buttons: the host answers play, pause and skipping itself.
        #expect(HostMediaPlayback.remote(.pause))
        #expect(text("state") == "Paused" && text("reason") == "Paused from the system\u{27}s controls")
        #expect(HostMediaPlayback.remote(.play) && text("state") == "Playing" && text("reason") == "")
        player.currentTime = 20
        #expect(HostMediaPlayback.remote(.skipForward) && platform.shown?.position == 30)

        // Next and previous are the app's: it knows the list.
        #expect(HostMediaPlayback.remote(.next))
        #expect(player.source == song("noon.mp3") && text("title") == "Noon, The Examples")
        #expect(platform.shown?.title == "Noon" && text("state") == "Paused", "loading")
        player.finishLoading()
        #expect(text("state") == "Playing", "asked to play before it was ready")
        #expect(HostMediaPlayback.remote(.previous) && player.source == song("morning.mp3"))
        player.finishLoading()

        // When a song ends, the app starts the next.
        player.player?.ended()
        #expect(player.source == song("noon.mp3"))
        player.finishLoading()
        #expect(text("state") == "Playing")
        try tap("Next")
        try tap("Next")
        #expect(text("title") == "Morning, The Examples", "round to the first again")
        player.finishLoading()

        // It plays on when the app leaves the front, and holds the app.
        HostMediaPlayback.applicationDidEnterBackground()
        #expect(text("state") == "Playing" && HostMediaPlayback.holdsApp)

        // A call interrupts, and then it goes on.
        HostMediaPlayback.interruptionBegan()
        #expect(text("state") == "Paused" && text("reason") == "Interrupted")
        HostMediaPlayback.interruptionEnded(shouldResume: true)
        #expect(text("state") == "Playing")
        HostMediaPlayback.outputRouteWasLost()
        #expect(text("reason") == "Headphones unplugged" && !HostMediaPlayback.holdsApp)

        // The video is another player, and its node says which.
        shown = try #require(platform.shown)
        let node = try #require(mediaNode("VideoPlayer", in: renderer.screen))
        guard case .int(let identifier)? = node.props["player"] else {
            Issue.record("the node names its player")
            return
        }
        let video = try #require(platform.engines.last)
        #expect(platform.engines.count == 2 && video !== player)
        #expect(HostMediaPlayback.player(for: Int32(identifier))?.engine === video)
        #expect(node.props["controls"] == "platform" && node.props["scaling"] == "fit")
        try tap("Show Video")
        #expect(video.source == .url("https://example.com/trailer.mp4"))
        #expect(platform.shown == shown, "the video isn't what's playing")
    }
}
