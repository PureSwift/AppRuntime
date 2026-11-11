import DynamicRuntime
import DynamicUI
import RuntimeABI

/// An app's top level: SwiftUI's `App`, without `@main`. The host owns
/// `main`, so the app starts from `rt_main`:
///
/// ```swift
/// struct CounterApp: App {
///     var body: some Scene {
///         WindowGroup { CounterView() }
///     }
/// }
///
/// @_expose(wasm, "rt_main")
/// @c(rt_main)
/// public func appMain() -> rt_status {
///     Runtime.main { CounterApp.run() }
/// }
/// ```
public protocol App {

    associatedtype Body: Scene

    @SceneBuilder var body: Body { get }

    init()
}

extension App {

    /// Shows the app's scene through the host's `Renderer`. Returns
    /// `notFound` if the host has no renderer.
    public static func run() -> RuntimeStatus {
        Self().body._start()
    }
}

/// Part of an app's interface. One window group for now.
public protocol Scene {

    func _start() -> RuntimeStatus
}

public struct WindowGroup<Content: View>: Scene {

    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public func _start() -> RuntimeStatus {
        HostRenderer.start(content)
    }
}

@resultBuilder
public enum SceneBuilder {

    public static func buildBlock<Content: Scene>(_ content: Content) -> Content {
        content
    }
}

/// The connection to the host's `Renderer` (§9.3): sends trees as
/// `RenderCodec` bytes and turns its delegate calls into view graph events.
public final class HostRenderer: RenderSink, RendererDelegate {

    /// Running interfaces; they live as long as the app.
    nonisolated(unsafe) static var running: [ViewGraph] = []

    private var renderer: (any Renderer)?

    private unowned(unsafe) var graph: ViewGraph?

    init() { }

    /// Starts showing `root`. The first tree goes out before control returns
    /// to the host.
    public static func start<Root: View>(_ root: Root) -> RuntimeStatus {
        guard RendererProxy.isAvailable else { return .notFound }
        let connection = HostRenderer()
        let graph = ViewGraph(root, sink: connection)
        connection.graph = graph
        connection.renderer = RendererProxy.make(connection)
        running.append(graph)
        if GuestExecutor.isInHostCall {
            graph.setNeedsUpdate()
        } else {
            graph.update()
        }
        return .ok
    }

    // MARK: RenderSink

    public func apply(_ tree: RenderNode) {
        renderer?.apply(RenderCodec.encode(tree))
    }

    public func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        renderer?.replaceSubtree(RenderCodec.encode(id: id), tree: RenderCodec.encode(subtree))
    }

    // MARK: RendererDelegate

    public func event(_ node: [UInt8], kind: Int32, payload: [UInt8]) {
        guard let graph,
              let id = try? RenderCodec.decode(id: node),
              let kind = RenderEventKind(rawValue: kind) else {
            return
        }
        let value = payload.isEmpty ? nil : try? RenderCodec.decode(payload: payload)
        graph.handle(id, kind: kind, payload: value)
    }

    public func rowCount(_ list: [UInt8]) -> Int32 {
        guard let graph, let id = try? RenderCodec.decode(id: list) else { return 0 }
        return Int32(truncatingIfNeeded: graph.rowCount(id))
    }

    public func row(_ list: [UInt8], index: Int32) -> [UInt8] {
        guard let graph,
              let id = try? RenderCodec.decode(id: list),
              let row = graph.row(id, index: Int(index)) else {
            return []
        }
        return RenderCodec.encode(row)
    }
}
