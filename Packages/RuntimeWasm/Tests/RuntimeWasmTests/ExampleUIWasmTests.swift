import Foundation
import Testing
import DynamicUI
import RuntimeABI
import RuntimeNative
import RuntimeWasm

/// A host's renderer for the example UI app: decodes trees and keeps the
/// screen current, as a player would.
final class WasmTestRenderer: Renderer {

    nonisolated(unsafe) static var last: WasmTestRenderer?

    let delegate: any RendererDelegate

    var screen: RenderNode?

    var applies = 0

    var replacements = 0

    init(delegate: any RendererDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any RendererDelegate) -> WasmTestRenderer {
        let renderer = WasmTestRenderer(delegate: delegate)
        last = renderer
        return renderer
    }

    func apply(_ tree: [UInt8]) {
        screen = try! RenderCodec.decode(tree)
        applies += 1
    }

    func replaceSubtree(_ id: [UInt8], tree: [UInt8]) {
        let id = try! RenderCodec.decode(id: id)
        let subtree = try! RenderCodec.decode(tree)
        #expect(screen?.replace(id, with: subtree) == true, "replaced a node on screen")
        replacements += 1
    }

    func send(_ node: RenderNode, _ kind: RenderEventKind, _ payload: PropValue? = nil) {
        delegate.event(RenderCodec.encode(id: node.id), kind: kind.rawValue,
                       payload: payload.map { RenderCodec.encode(payload: $0) } ?? [])
    }
}

extension RenderNode {

    func first(where matches: (RenderNode) -> Bool) -> RenderNode? {
        if matches(self) { return self }
        for child in children {
            if let found = child.first(where: matches) { return found }
        }
        return nil
    }

    func identified(_ identifier: String) -> RenderNode? {
        first { $0.modifiers.contains { $0.kind == "accessibilityIdentifier" && $0.args["identifier"] == .string(identifier) } }
    }

    func button(_ title: String) -> RenderNode? {
        first { ($0.type == "Button" || $0.type == "NavigationLink") && $0.children.first?.props["text"] == .string(title) }
    }
}

/// The example UI app as App.wasm under WasmKit, driven like a player: the
/// SwiftUI frontend, Observation stopgap, guest executor and render IR end
/// to end in an Embedded guest. Part of `WasmShimTests`, which is serialized,
/// since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleUI`; skipped without it.
    static var exampleUIURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent() // Packages/RuntimeWasm
            .deletingLastPathComponent()
            .appendingPathComponent(".build/guest/ExampleUI/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleUIURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleUI"))
    func exampleUIInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        WasmTestRenderer.last = nil

        let app = try WasmApp(bytes: Array(try Data(contentsOf: Self.exampleUIURL)), runtime: native.runtime, capabilities: [])
        #expect(WasmApp.contracts(of: app.module)?.map(\.name).contains("org.pureswift.ui.Renderer") == true)
        #expect(try app.start() == .ok)
        let host = try #require(WasmTestRenderer.last)
        var screen = try #require(host.screen)
        #expect(host.applies == 1)
        #expect(screen.type == "NavStack")
        #expect(screen.children.map { $0.props["title"] } == ["Example"])
        #expect(screen.identified("greeting")?.props["text"] == "Hello, World!")
        #expect(screen.identified("count")?.props["text"] == "0")

        // Tapping + updates only the count.
        host.send(try #require(screen.button("+")), .tap)
        host.send(try #require(screen.button("+")), .tap)
        screen = try #require(host.screen)
        #expect(screen.identified("count")?.props["text"] == "2")
        #expect(host.applies == 1)
        #expect(host.replacements > 0)

        // Typing goes through the binding to the observable model.
        let field = try #require(screen.first { $0.type == "TextField" })
        host.send(field, .change, "Ada")
        screen = try #require(host.screen)
        #expect(screen.identified("greeting")?.props["text"] == "Hello, Ada!")
        #expect(screen.first { $0.type == "TextField" }?.props["text"] == "Ada")

        // The list is lazy; the host asks for the rows it shows.
        let list = try #require(screen.first { $0.type == "List" })
        let listID = RenderCodec.encode(id: list.id)
        #expect(list.count == 3)
        #expect(host.delegate.rowCount(listID) == 3)
        let row = try RenderCodec.decode(host.delegate.row(listID, index: 1))
        #expect(row.type == "NavigationLink")
        #expect(row.children.first?.props["text"] == "Banana")

        // Following a row's link pushes its detail screen.
        host.send(row, .tap)
        screen = try #require(host.screen)
        #expect(screen.children.map { $0.props["title"] } == ["Example", "Banana"])
        host.send(try #require(screen.children[1].button("Like (0)")), .tap)
        screen = try #require(host.screen)
        #expect(screen.children[1].button("Like (1)") != nil)

        // Back.
        host.send(screen, .pop, 1)
        #expect(host.screen?.children.count == 1)
    }
}
