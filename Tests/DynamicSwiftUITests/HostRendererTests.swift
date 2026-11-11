import Testing
@testable import DynamicSwiftUI
import DynamicRuntime
import DynamicUI
import RuntimeNative

/// A host's renderer: decodes what the guest sends, as a player would.
final class TestRenderer: Renderer {

    nonisolated(unsafe) static var last: TestRenderer?

    let delegate: any RendererDelegate

    var trees: [RenderNode] = []

    var replacements: [(id: RenderNode.ID, subtree: RenderNode)] = []

    init(delegate: any RendererDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any RendererDelegate) -> TestRenderer {
        let renderer = TestRenderer(delegate: delegate)
        last = renderer
        return renderer
    }

    func apply(_ tree: [UInt8]) {
        trees.append(try! RenderCodec.decode(tree))
    }

    func replaceSubtree(_ id: [UInt8], tree: [UInt8]) {
        replacements.append((try! RenderCodec.decode(id: id), try! RenderCodec.decode(tree)))
    }

    /// The user acts on a node, as a player reports it.
    func send(_ node: RenderNode.ID, _ kind: RenderEventKind, _ payload: PropValue? = nil) {
        delegate.event(RenderCodec.encode(id: node), kind: kind.rawValue,
                       payload: payload.map { RenderCodec.encode(payload: $0) } ?? [])
    }
}

/// The frontend through the native runtime: `HostRenderer` makes the host's
/// `Renderer`, and events come back through the delegate proxy and
/// `rt_dispatch`, as in a native slice.
extension ViewGraphTests {

    func registerRenderer() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        TestRenderer.last = nil
    }

    @Test func hostRendererSendsTreesAndHandlesEvents() throws {
        registerRenderer()
        // As rt_main would: the first tree goes out before control returns.
        let status = GuestExecutor.enter { HostRenderer.start(Counter()) }
        #expect(status == .ok)
        let host = try #require(TestRenderer.last)
        #expect(host.trees.count == 1)
        let tree = try #require(host.trees.first)
        #expect(tree.texts == ["Count: 0", "Increment"])

        // A tap goes through rt_dispatch; the update goes out as it returns.
        let button = try #require(tree.find("Button"))
        host.send(button.id, .tap)
        #expect(host.trees.count == 1)
        #expect(host.replacements.map(\.subtree.texts) == [["Count: 1"]])

        // Events the guest doesn't know are ignored.
        host.send(0xDEAD, .tap)
        host.delegate.event([1, 2, 3], kind: 99, payload: [0xFF])
        #expect(host.replacements.count == 1)
    }

    @Test func hostRendererServesLazyRows() throws {
        registerRenderer()
        let items = (0..<50).map { Item(id: $0, title: "row \($0)") }
        _ = GuestExecutor.enter { HostRenderer.start(LazyRows(items: items)) }
        let host = try #require(TestRenderer.last)
        let list = try #require(host.trees.first)
        let listID = RenderCodec.encode(id: list.id)
        #expect(host.delegate.rowCount(listID) == 50)
        let row = try RenderCodec.decode(host.delegate.row(listID, index: 7))
        #expect(row.texts == ["row 7 0"])
        #expect(host.delegate.row(listID, index: 50).isEmpty, "out of range")

        host.send(row.id, .tap)
        let updated = try RenderCodec.decode(host.delegate.row(listID, index: 7))
        #expect(updated.texts == ["row 7 1"])
    }

}
