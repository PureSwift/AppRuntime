import DynamicRuntime
import DynamicMedia
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example media app: a small music player. It plays the songs in its
/// bundle one after another, says what's playing so the system can show
/// it, answers next and previous, plays on in the background where the
/// manifest allows, and shows a video beside it.

struct Song {
    let title: String
    let artist: String
    let file: String
}

/// The closures hold the jukebox, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Jukebox: @unchecked Sendable {

    static let songs: [Song] = [
        Song(title: "Morning", artist: "The Examples", file: "music/morning.mp3"),
        Song(title: "Noon", artist: "The Examples", file: "music/noon.mp3"),
        Song(title: "Night", artist: "The Examples", file: "music/night.mp3"),
    ]

    var title: String = "Nothing playing"

    var status: String = ""

    @ObservationIgnored var index: Int = 0

    @ObservationIgnored let player = MediaPlayer()

    /// A second player, for the picture.
    @ObservationIgnored let video = MediaPlayer()

    func start() {
        // Where the manifest allows, the music goes on when the app
        // leaves the front.
        player.playsInBackground = true
        status = MediaPlayer.canPlayInBackground ? "Plays in the background" : "Plays in front only"
        // The list is the app's, so next and previous are too. Play,
        // pause and seeking the host answers itself.
        player.onNextTrack = { self.step(1) }
        player.onPreviousTrack = { self.step(-1) }
        player.skipIntervals = (backward: 10, forward: 10)
        // When a song ends, the next one starts.
        player.onEnd = { self.step(1) }
        player.onFailure = { error in
            self.status = "Couldn't play: error \(error.code.rawValue)"
        }
        load(0)
    }

    func load(_ index: Int) {
        let songs = Self.songs
        self.index = (index % songs.count + songs.count) % songs.count
        let song = songs[self.index]
        title = "\(song.title), \(song.artist)"
        player.load(.resource(song.file))
        // Said with each source: the host adds the position itself.
        player.nowPlaying = NowPlayingInfo(title: song.title, artist: song.artist, album: "Examples",
                                           artwork: .file(.bundle / "music/cover.png"))
    }

    /// To another song, playing.
    func step(_ by: Int) {
        load(index + by)
        player.play()
    }

    func toggle() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func showVideo() {
        video.load(.url("https://example.com/trailer.mp4"))
    }
}

struct ContentView: View {

    let jukebox: Jukebox

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(jukebox.title)
                .accessibilityIdentifier("title")
            Text(jukebox.player.isPlaying ? "Playing" : "Paused")
                .accessibilityIdentifier("state")
            Text(reason)
                .accessibilityIdentifier("reason")
            HStack(spacing: 8) {
                Button("Previous") { jukebox.step(-1) }
                Button(jukebox.player.isPlaying ? "Pause" : "Play") { jukebox.toggle() }
                Button("Next") { jukebox.step(1) }
            }
            Button("Show Video") { jukebox.showVideo() }
            VideoPlayer(jukebox.video)
                .frame(height: 120)
            Text(jukebox.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }

    /// Why it isn't playing, where that's worth saying.
    var reason: String {
        guard !jukebox.player.isPlaying else { return "" }
        switch jukebox.player.pauseReason {
        case .user: return "Paused from the system's controls"
        case .background: return "Paused for the background"
        case .interrupted: return "Interrupted"
        case .routeChanged: return "Headphones unplugged"
        default: return ""
        }
    }
}

struct ExampleMediaApp: App {

    let jukebox = Jukebox()

    init() {
        jukebox.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(jukebox: jukebox)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleMediaMain() -> rt_status {
    Runtime.main { ExampleMediaApp.run() }
}
