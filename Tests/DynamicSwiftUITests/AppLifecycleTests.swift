import Testing
@testable import DynamicSwiftUI
import DynamicRuntime
import DynamicUI
import RuntimeNative

/// A host's `Application`: writes down what it's asked, and keeps the
/// delegate to report back as a platform would.
final class TestApplication: Application {

    nonisolated(unsafe) static var last: TestApplication?

    /// What `state()` answers when the application is made.
    nonisolated(unsafe) static var initial = ApplicationState.active

    let delegate: any ApplicationDelegate

    var opened: [String] = []

    var idle: [Bool] = []

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any ApplicationDelegate) -> TestApplication {
        let application = TestApplication(delegate: delegate)
        last = application
        return application
    }

    func state() -> Int32 { Self.initial.rawValue }

    func openURL(_ url: String) -> Bool {
        opened.append(url)
        return !url.hasPrefix("nowhere:")
    }

    func setIdleTimerDisabled(_ disabled: Bool) {
        idle.append(disabled)
    }
}

/// A host's `Application` with only the defaults.
final class PlainApplication: Application {

    static func make(_ delegate: any ApplicationDelegate) -> PlainApplication { PlainApplication() }

    func state() -> Int32 { 0 }
}

extension RenderNode {

    /// Depth first, the first button whose label says `title`.
    func button(_ title: String) -> RenderNode? {
        if type == "Button", texts.contains(title) { return self }
        for child in children {
            if let found = child.button(title) { return found }
        }
        return nil
    }
}

/// Plain, not `@Observable`: the tests update the graph themselves.
final class Shown {
    var urls: [String] = []
    var answers: [Bool] = []
    var first = true
    var second = true
    var keepsAwake = true
}

struct Caller: View {

    @Environment(.openURL) var openURL

    let shown: Shown

    var body: some View {
        VStack {
            Button("Call") { openURL("tel:5551234") }
            Button("Nowhere") {
                openURL("nowhere:x") { shown.answers.append($0) }
            }
            Link("Website", destination: "https://example.com")
        }
    }
}

struct Phase: View {

    @Environment(.scenePhase) var scenePhase

    var body: some View {
        Text(scenePhase == .active ? "active" : scenePhase == .inactive ? "inactive" : "background")
    }
}

struct Receiver: View {

    let shown: Shown

    var body: some View {
        VStack {
            if shown.first {
                Text("First").onOpenURL { shown.urls.append("first \($0)") }
            }
            if shown.second {
                Text("Second").onOpenURL { shown.urls.append("second \($0)") }
            }
        }
    }
}

struct Awake: View {

    let shown: Shown

    var body: some View {
        VStack {
            if shown.first {
                Text("Video").idleTimerDisabled(shown.keepsAwake)
            }
            if shown.second {
                Text("Timer").idleTimerDisabled()
            }
        }
    }
}

/// The frontend's `Application` through the native runtime. Part of
/// `ViewGraphTests`, which is serialized: the app's lifecycle is shared.
extension ViewGraphTests {

    func startApplication() throws -> TestApplication? {
        try startApplication(TestApplication.self)
    }

    func startApplication<A: Application>(_ type: A.Type) throws -> TestApplication? {
        let native = NativeRuntime.shared
        native.capabilities = nil
        ApplicationProxy.register(type, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
        TestApplication.last = nil
        AppLifecycle.shared.reset()
        AppLifecycle.shared.start()
        #expect(AppLifecycle.shared.application != nil)
        return TestApplication.last
    }

    // MARK: Opening URLs

    @Test func codeOpensURLsThroughTheHost() throws {
        defer { AppLifecycle.shared.reset() }
        let host = try #require(try startApplication())
        let shown = Shown()
        let sink = TestSink()
        let graph = ViewGraph(Caller(shown: shown), sink: sink)
        graph.update()
        #expect(graph.handle(try #require(sink.screen?.button("Call")).id, kind: .tap))
        #expect(graph.handle(try #require(sink.screen?.button("Nowhere")).id, kind: .tap))
        #expect(host.opened == ["tel:5551234", "nowhere:x"])
        #expect(shown.answers == [false], "the host's answer")

        // With no action of the app's, a link is the host's to open.
        let link = try #require(sink.screen?.find("Link"))
        #expect(link.props == ["url": "https://example.com"])
        #expect(!graph.handle(link.id, kind: .tap))
    }

    @Test func theAppsActionsComeFirstInnermostFirst() throws {
        defer { AppLifecycle.shared.reset() }
        let host = try #require(try startApplication())
        var asked: [String] = []
        let shown = Shown()
        let outer = OpenURLAction { url in
            asked.append("outer \(url)")
            return url.hasPrefix("outer:") ? .handled : .systemAction
        }
        let inner = OpenURLAction { url in
            asked.append("inner \(url)")
            if url.hasPrefix("tel:") { return .discarded }
            if url.hasPrefix("https://example.com") { return .systemAction("outer:website") }
            return .systemAction
        }
        let sink = TestSink()
        let graph = ViewGraph(Caller(shown: shown).environment(.openURL, inner).environment(.openURL, outer), sink: sink)
        graph.update()

        // Discarded by the inner action: nothing opens.
        #expect(graph.handle(try #require(sink.screen?.button("Call")).id, kind: .tap))
        #expect(asked == ["inner tel:5551234"])
        #expect(host.opened.isEmpty)

        // Through both to the host, which says no.
        #expect(graph.handle(try #require(sink.screen?.button("Nowhere")).id, kind: .tap))
        #expect(asked.suffix(2) == ["inner nowhere:x", "outer nowhere:x"])
        #expect(host.opened == ["nowhere:x"] && shown.answers == [false])

        // A link asks the app: the host sends a tap. The inner action
        // changes the URL, and the outer one handles what it's given.
        let link = try #require(sink.screen?.find("Link"))
        #expect(link.props["intercepts"] == .bool(true))
        #expect(graph.handle(link.id, kind: .tap))
        #expect(asked.suffix(2) == ["inner https://example.com", "outer outer:website"])
        #expect(host.opened == ["nowhere:x"], "handled by the app")
    }

    @Test func aHostWithOnlyTheDefaultsOpensNothing() throws {
        defer { AppLifecycle.shared.reset() }
        _ = try startApplication(PlainApplication.self)
        let shown = Shown()
        let sink = TestSink()
        let graph = ViewGraph(Caller(shown: shown), sink: sink)
        graph.update()
        #expect(graph.handle(try #require(sink.screen?.button("Nowhere")).id, kind: .tap))
        #expect(shown.answers == [false])
        // And nothing to keep the screen awake with, without complaint.
        AppLifecycle.shared.add(IdleRequest())
    }

    // MARK: URLs the app is opened with

    @Test func aURLWaitsForAViewToTakeIt() throws {
        defer { AppLifecycle.shared.reset() }
        let host = try #require(try startApplication())
        // The URL that launched the app, before the first tree.
        #expect(host.delegate.open(host, url: "exampleui://launch"))
        #expect(AppLifecycle.shared.pendingURLs == ["exampleui://launch"])

        let shown = Shown()
        shown.second = false
        let sink = TestSink()
        let graph = ViewGraph(Receiver(shown: shown), sink: sink)
        graph.update()
        #expect(shown.urls == ["first exampleui://launch"], "the first to appear")
        #expect(AppLifecycle.shared.pendingURLs.isEmpty)

        // Every view on screen with one gets the next.
        shown.second = true
        graph.update()
        #expect(host.delegate.open(host, url: "exampleui://next"))
        #expect(shown.urls.suffix(2) == ["first exampleui://next", "second exampleui://next"])

        // None on screen: it waits again.
        shown.first = false
        shown.second = false
        graph.update()
        #expect(host.delegate.open(host, url: "exampleui://later"))
        #expect(shown.urls.count == 3)
        #expect(AppLifecycle.shared.pendingURLs == ["exampleui://later"])
    }

    // MARK: Scene phase

    @Test func theScenePhaseFollowsTheApplication() throws {
        defer {
            AppLifecycle.shared.reset()
            TestApplication.initial = .active
        }
        TestApplication.initial = .inactive
        let host = try #require(try startApplication())
        #expect(AppLifecycle.shared.phase == .inactive, "as it was when the app started")
        let sink = TestSink()
        let graph = ViewGraph(Phase(), sink: sink)
        graph.update()
        #expect(sink.screen?.find("Text")?.props["text"] == "inactive")

        host.delegate.didChangeState(host, state: ApplicationState.background.rawValue)
        graph.update()
        #expect(sink.screen?.find("Text")?.props["text"] == "background")
        host.delegate.didChangeState(host, state: ApplicationState.active.rawValue)
        host.delegate.didChangeState(host, state: 99)
        graph.update()
        #expect(sink.screen?.find("Text")?.props["text"] == "active", "a state from a newer host is ignored")
        #expect(ScenePhase.background < .inactive && ScenePhase.inactive < .active)
    }

    @Test func aPhaseChangeUpdatesTheRunningInterface() throws {
        defer { AppLifecycle.shared.reset() }
        registerRenderer()
        let host = try #require(try startApplication())
        _ = GuestExecutor.enter { HostRenderer.start(Phase()) }
        let graph = try #require(HostRenderer.running.last)
        #expect(!graph.needsUpdate)
        AppLifecycle.shared.didChangeState(host, state: ApplicationState.background.rawValue)
        #expect(graph.needsUpdate)
        graph.update()
    }

    // MARK: Keeping the screen awake

    @Test func theScreenStaysAwakeWhileAnyViewAsks() throws {
        defer { AppLifecycle.shared.reset() }
        let host = try #require(try startApplication())
        let shown = Shown()
        let sink = TestSink()
        let graph = ViewGraph(Awake(shown: shown), sink: sink)
        graph.update()
        #expect(host.idle == [true], "two views, one call")

        // One stops asking; the other still does.
        shown.keepsAwake = false
        graph.update()
        #expect(host.idle == [true])
        shown.second = false
        graph.update()
        #expect(host.idle == [true, false])

        // The first asks again, then goes.
        shown.keepsAwake = true
        graph.update()
        #expect(host.idle == [true, false, true])
        shown.first = false
        graph.update()
        #expect(host.idle == [true, false, true, false])
        #expect(!AppLifecycle.shared.isIdleTimerDisabled)
    }
}
