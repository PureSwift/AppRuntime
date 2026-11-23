import Testing
import CRuntime
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeNative

/// A host's `Application` for the example: writes down what the app asks,
/// and keeps the delegate to report back as a platform would.
final class LinkedTestApplication: Application {

    nonisolated(unsafe) static var last: LinkedTestApplication?

    let delegate: any ApplicationDelegate

    var opened: [String] = []

    var idle: [Bool] = []

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any ApplicationDelegate) -> LinkedTestApplication {
        let application = LinkedTestApplication(delegate: delegate)
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
final class TestRenderer: Renderer {

    nonisolated(unsafe) static var last: TestRenderer?

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

    static func make(_ delegate: any RendererDelegate) -> TestRenderer {
        let renderer = TestRenderer(delegate: delegate)
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

/// `ExampleUI`'s library, driven like a player: the SwiftUI frontend,
/// Observation stopgap, guest executor and render IR in an Embedded guest,
/// as a native slice or through wasm2c (see `Package.swift`). The same
/// checks as `RuntimeWasm`'s WasmKit test. Part of `LinkedSliceTests`, which
/// is serialized, since both use `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleUI: Bool {
        #if LINKED_EXAMPLEUI
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleUI, "Link ExampleUI's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleUI() throws {
        #if LINKED_EXAMPLEUI
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        ApplicationProxy.register(LinkedTestApplication.self, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
        LinkedTestApplication.last = nil
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        do {
            var screen: RenderNode
            let host = try #require(TestRenderer.last)
            screen = try #require(host.screen)
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
            let swipe = try RenderCodec.decode(host.delegate.row(listID, index: 1))
            #expect(swipe.type == "SwipeActions")
            let menu = try #require(swipe.children.first)
            #expect(menu.type == "ContextMenu")
            let row = try #require(menu.children.first)
            #expect(row.type == "NavigationLink")
            #expect(row.children.first?.props["text"] == "Banana")
            #expect(swipe.children.last?.props["role"] == "destructive")

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
            // The app's own `Application`: a URL it's opened with reaches its
            // `onOpenURL`.
            let application = try #require(LinkedTestApplication.last)
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
        }
        #endif
    }
}
