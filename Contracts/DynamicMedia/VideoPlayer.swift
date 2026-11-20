import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Shows a player's picture, as AVKit's view does. It takes the space it's
/// offered and fits the picture inside it.
///
/// ```swift
/// VideoPlayer(player)
///     .frame(height: 220)
/// ```
///
/// To only show a URL, give that; the view keeps a player of its own, and
/// loads again when the URL it's given changes:
///
/// ```swift
/// VideoPlayer(url: "https://example.com/trailer.mp4")
/// ```
///
/// A `VideoPlayer` node has `player`, the identifier of the host's player
/// (`MediaPlayback.identifier()`), with `scaling` and `controls`. The host
/// shows that player's picture there. When the node goes the player stays:
/// it's still loaded, and may be playing.
public struct VideoPlayer: View {

    let player: MediaPlayer?

    let url: String?

    let scaling: VideoScaling

    let controls: VideoControls

    /// The player of a view made from a URL, kept across updates.
    @State private var owned = OwnedPlayer()

    /// `controls: .none` shows only the picture, for an app that draws its
    /// own from the player's properties.
    public init(_ player: MediaPlayer, scaling: VideoScaling = .fit, controls: VideoControls = .platform) {
        self.player = player
        self.url = nil
        self.scaling = scaling
        self.controls = controls
    }

    public init(url: String?, scaling: VideoScaling = .fit, controls: VideoControls = .platform) {
        self.player = nil
        self.url = url
        self.scaling = scaling
        self.controls = controls
    }

    public var body: some View {
        _RenderNodeView("VideoPlayer", props: [
            "player": .int(Int(shown.identifier)),
            "scaling": .string(scaling.rawValue),
            "controls": .string(controls.rawValue),
        ])
    }

    private var shown: MediaPlayer {
        if let player {
            return player
        }
        owned.show(url)
        return owned.player
    }
}

/// A `VideoPlayer(url:)`'s own player, and the URL it last asked it for.
final class OwnedPlayer {

    let player = MediaPlayer()

    private var requested: String?

    func show(_ url: String?) {
        guard url != requested else { return }
        requested = url
        if let url {
            player.load(.url(url))
        } else {
            player.unload()
        }
    }
}
