import DynamicRuntime

/// The host's UI player (§9.3): it interprets render trees with the platform
/// toolkit, and owns layout, input, animation and accessibility.
///
/// Trees, subtrees and node IDs are `RenderCodec` bytes. One update is one
/// call.
@DynamicRuntime("org.pureswift.ui.Renderer")
public protocol Renderer: AnyObject {

    static func make(_ delegate: RendererDelegate) -> Self

    /// Replaces everything on screen with `tree`.
    func apply(_ tree: [UInt8])

    /// Replaces the node `id` (an 8-byte node ID) and its subtree with `tree`,
    /// updating native views in place.
    func replaceSubtree(_ id: [UInt8], tree: [UInt8])
}

/// The guest's side of a renderer (§9.3). Called on the main thread.
@DynamicCallback("org.pureswift.ui.RendererDelegate")
public protocol RendererDelegate: AnyObject {

    /// The user acted on node `node` (an 8-byte node ID). `kind` is a
    /// `RenderEventKind`; `payload` is a `RenderCodec` payload, or empty.
    func event(_ node: [UInt8], kind: Int32, payload: [UInt8])

    /// Rows in the lazy container `list`.
    func rowCount(_ list: [UInt8]) -> Int32

    /// Row `index` of the lazy container `list`, as an encoded tree. The host
    /// asks only for the rows it shows.
    func row(_ list: [UInt8], index: Int32) -> [UInt8]
}
