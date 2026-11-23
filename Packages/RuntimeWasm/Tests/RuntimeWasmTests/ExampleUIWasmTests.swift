import Foundation
import Testing
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeNative
import RuntimeWasm

/// A host's `Application` for the example: writes down what the app asks,
/// and keeps the delegate to report back as a platform would.
final class WasmTestApplication: Application {

    nonisolated(unsafe) static var last: WasmTestApplication?

    let delegate: any ApplicationDelegate

    var opened: [String] = []

    var idle: [Bool] = []

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any ApplicationDelegate) -> WasmTestApplication {
        let application = WasmTestApplication(delegate: delegate)
        last = application
        return application
    }

    func state() -> Int32 { ApplicationState.active.rawValue }

    func openURL(_ url: String) -> Bool {
        opened.append(url)
        return true
    }

    func setIdleTimerDisabled(_ disabled: Bool) {
        idle.append(disabled)
    }
}

/// A host's renderer for the example UI app: decodes trees and keeps the
/// screen current, as a player would.
final class WasmTestRenderer: Renderer {

    nonisolated(unsafe) static var last: WasmTestRenderer?

    /// What `environment()` answers: `nil` is a renderer that reports no
    /// values, and draws no split views.
    nonisolated(unsafe) static var window: RenderEnvironment?

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

    func environment() -> [UInt8] {
        Self.window?.bytes ?? []
    }

    /// The window's values changed, as a player reports it.
    func report(_ window: RenderEnvironment) {
        delegate.event(RenderCodec.encode(id: RenderNode.windowID), kind: RenderEventKind.environment.rawValue,
                       payload: RenderCodec.encode(payload: window.payload))
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
        ApplicationProxy.register(WasmTestApplication.self, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
        WasmTestApplication.last = nil
        WasmTestRenderer.last = nil

        let app = try WasmApp(bytes: Array(try Data(contentsOf: Self.exampleUIURL)), runtime: native.runtime, capabilities: [])
        #expect(WasmApp.contracts(of: app.module)?.map(\.name).contains("org.pureswift.ui.Renderer") == true)
        #expect(try app.start() == .ok)
        let host = try #require(WasmTestRenderer.last)
        var screen = try #require(host.screen)
        #expect(host.applies == 1)
        #expect(screen.type == "Commands" && screen.children.first?.type == "NavStack", "the app's menus around its window")
        #expect(screen.children[0].children.map { $0.props["title"] } == ["Example"])
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
        let swipe = try RenderCodec.decode(host.delegate.row(listID, index: 1))
        #expect(swipe.type == "SwipeActions")
        let menu = try #require(swipe.children.first)
        #expect(menu.type == "ContextMenu")
        let row = try #require(menu.children.first)
        #expect(row.type == "NavigationLink")
        #expect(row.children.first?.props["text"] == "Banana")

        // Following a row's link pushes its detail screen.
        host.send(row, .tap)
        screen = try #require(host.screen)
        #expect(screen.children[0].children.map { $0.props["title"] } == ["Example", "Banana"])
        host.send(try #require(screen.children[0].children[1].button("Like (0)")), .tap)
        screen = try #require(host.screen)
        #expect(screen.children[0].children[1].button("Like (1)") != nil)

        // Back.
        host.send(screen.children[0], .pop, 1)
        #expect(host.screen?.children.first?.children.count == 1)
        // The app's own `Application`: a URL it's opened with reaches its
        // `onOpenURL`.
        let application = try #require(WasmTestApplication.last)
        #expect(application.delegate.open(application, url: "exampleui://fruit/3"))

        // The sheet's System tab.
        host.send(try #require(host.screen?.button("About")), .tap)
        screen = try #require(host.screen)
        #expect(screen.identified("lastURL")?.props["text"] == "Opened with exampleui://fruit/3")
        #expect(screen.identified("phase")?.props["text"] == "Phase: active")

        // Opening a URL from code goes to the host, which answers.
        host.send(try #require(screen.button("Open swift.org")), .tap)
        #expect(application.opened == ["https://swift.org"])
        #expect(host.screen?.identified("opened")?.props["text"] == "Opened")

        // A link the app handles itself: the host sends a tap, and opens nothing.
        let link = try #require(screen.first { $0.type == "Link" && $0.props["url"] == "exampleui://fruit/2" })
        #expect(link.props["intercepts"] == .bool(true))
        host.send(link, .tap)
        #expect(application.opened == ["https://swift.org"])
        #expect(host.screen?.identified("lastURL")?.props["text"] == "Opened with exampleui://fruit/2")

        // Keeping the screen awake, and the phase.
        host.send(try #require(screen.first { $0.type == "Toggle" }), .change, .bool(true))
        #expect(application.idle == [true])
        application.delegate.didChangeState(application, state: ApplicationState.background.rawValue)
        #expect(host.screen?.identified("phase")?.props["text"] == "Phase: background")

        // Closing the sheet takes the view that kept the screen awake.
        host.send(try #require(host.screen?.identified("done")), .tap)
        #expect(application.idle == [true, false])

        // The app's menu: a command, with its shortcut, that adds a fruit.
        let root = try #require(host.screen)
        let fruitMenu = try #require(root.children.last)
        #expect(fruitMenu.type == "CommandMenu" && fruitMenu.props["title"] == "Fruit")
        let add = try #require(fruitMenu.button("Add Fruit"))
        #expect(add.modifiers.first { $0.kind == "keyboardShortcut" }?.args == ["key": "n", "modifiers": PropValue.array(["command"])])
        let rows = try #require(root.first { $0.type == "List" }?.count)
        host.send(add, .tap)
        #expect(host.screen?.first { $0.type == "List" }?.count == rows + 1)
        #expect(root.button("About")?.modifiers.first { $0.kind == "keyboardShortcut" }?.args["key"] == "i")

        // The sheet's detents, and a card dragged and pinned in its Card tab.
        host.send(try #require(host.screen?.button("About")), .tap)
        let sheet = try #require(host.screen?.first { $0.type == "Sheet" })
        let content = sheet.children[1]
        #expect(content.modifiers.first { $0.kind == "presentationDetents" }?.args == ["detents": PropValue.array(["medium", "large"])])
        #expect(content.modifiers.first { $0.kind == "presentationDragIndicator" }?.args == ["visibility": "visible"])
        #expect(content.button("Done")?.modifiers.first { $0.kind == "keyboardShortcut" }?.args == ["key": "return", "modifiers": PropValue.array([])])
        let card = try #require(host.screen?.identified("card"))
        #expect(card.modifiers.map { $0.kind }.contains("dragGesture") && card.modifiers.map { $0.kind }.contains("longPressGesture"))
        host.send(card, .drag, .array([0, 5, 5, 35, 45, 35, 45].map { .double($0) }))
        #expect(host.screen?.identified("cardPosition")?.props["text"] == "30, 40, dragging")
        host.send(card, .drag, .array([1, 5, 5, 35, 45, 35, 45].map { .double($0) }))
        #expect(host.screen?.identified("cardPosition")?.props["text"] == "30, 40")
        host.send(card, .longPress)
        host.send(card, .drag, .array([0, 0, 0, 90, 90, 90, 90].map { .double($0) }))
        #expect(host.screen?.identified("cardPosition")?.props["text"] == "30, 40, pinned, dragging", "a pinned card stays")
        host.send(card, .drag, .array([2, 0, 0, 90, 90, 90, 90].map { .double($0) }))
        #expect(host.screen?.identified("cardPosition")?.props["text"] == "30, 40, pinned", "cancelled: no longer dragging")
        host.send(try #require(host.screen?.identified("done")), .tap)
    }
}
