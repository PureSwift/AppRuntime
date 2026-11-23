import Foundation
import Testing
import DynamicUI
import DynamicWebKit
import RuntimeABI
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// A host's page for the example web app: writes down what it's asked, and
/// keeps the delegate to report back as an engine would.
final class WasmTestWebContent: WebContent {

    nonisolated(unsafe) static var all: [WasmTestWebContent] = []

    /// Pages are 7, 8, 9… in the order they're made.
    nonisolated(unsafe) static var nextIdentifier: Int32 = 7

    let delegate: any WebContentDelegate

    let id: Int32

    var calls: [String] = []

    /// How it was made: "make" for the plain constructor, else the store
    /// and options it was made with.
    var made = "make"

    init(delegate: any WebContentDelegate) {
        self.delegate = delegate
        id = Self.nextIdentifier
        Self.nextIdentifier += 1
    }

    static func make(_ delegate: any WebContentDelegate) -> WasmTestWebContent {
        let content = WasmTestWebContent(delegate: delegate)
        all.append(content)
        return content
    }

    /// Every feature.
    static func features() -> Int32 { 4095 }

    static func make(_ delegate: any WebContentDelegate, dataStore: Int32, options: Int32) -> WasmTestWebContent {
        let content = make(delegate)
        content.made = "store \(dataStore) options \(options)"
        return content
    }

    func identifier() -> Int32 { id }

    func load(_ url: String) { calls.append("load \(url)") }

    func loadHTML(_ html: String, baseURL: String?) { calls.append("html") }

    func loadResource(_ path: String) { calls.append("resource \(path)") }

    func reload() { calls.append("reload") }

    func stopLoading() { calls.append("stop") }

    func goBack() { calls.append("back") }

    func goForward() { calls.append("forward") }

    func evaluateJavaScript(_ script: String, request: Int32) {
        calls.append("script \(request) \(script)")
    }

    func find(_ text: String, backwards: Bool, caseSensitive: Bool, request: Int32) { calls.append("find \(request) \(text)") }

    func answerPermission(_ request: Int32, granted: Bool) { calls.append("permission \(request) \(granted)") }

    func snapshot(_ width: Double, request: Int32) { calls.append("snapshot \(request) \(width)") }
}

/// The example web app as App.wasm under WasmKit, with the test standing in
/// for the browser engine: `WebPage`, `WebView` and the `WebContent`
/// contract end to end in an Embedded guest. Part of `WasmShimTests`, which
/// is serialized, since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleWeb`; skipped without it.
    static var exampleWebURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleWeb/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleWebURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleWeb"))
    func exampleWebInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        WebContentProxy.register(WasmTestWebContent.self, in: native)
        WebContentDelegateProxy.registerInterface(in: native)
        // Every host has files; a web app links them for where downloads
        // land, and declares them.
        HostFilesModule.register(in: native)
        WasmTestRenderer.last = nil
        WasmTestWebContent.all = []
        WasmTestWebContent.nextIdentifier = 7

        let bytes = Array(try Data(contentsOf: Self.exampleWebURL))
        // No capabilities: a web view needs none. Whether its pages reach
        // the network is the host's to enforce.
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        let content = try #require(contracts.first { $0.name == "org.pureswift.web.WebContent" })
        #expect(content.capability == nil)
        let problems = WasmApp.validate(app.module, runtime: native.runtime, capabilities: [])
        #expect(!problems.contains { $0.severity == .error }, "\(problems)")
        #expect(try app.start() == .ok)

        // One page in the host, loading the first address, shown by the node.
        let renderer = try #require(WasmTestRenderer.last)
        #expect(WasmTestWebContent.all.count == 1)
        let engine = try #require(WasmTestWebContent.all.first)
        #expect(engine.calls == ["load https://swift.org/"])
        var screen = try #require(renderer.screen)
        #expect(screen.first { $0.type == "WebView" }?.props["page"] == .int(7))
        #expect(screen.button("Back")?.modifiers.contains { $0.kind == "disabled" && $0.args["value"] == .bool(true) } == true)

        // The engine reports the load: progress shows, then the title.
        engine.delegate.didChangeLoading(engine, isLoading: true, progress: 0.3)
        screen = try #require(renderer.screen)
        #expect(screen.first { $0.type == "ProgressView" }?.props["value"] == .double(0.3))
        #expect(screen.button("Stop") != nil)
        // A redirect: the address field follows the page once it finishes.
        engine.delegate.didChangeURL(engine, url: "https://www.swift.org/")
        engine.delegate.didChangeTitle(engine, title: "Swift.org")
        engine.delegate.didChangeLoading(engine, isLoading: false, progress: 1)
        engine.delegate.didFinishNavigation(engine)
        screen = try #require(renderer.screen)
        #expect(screen.identified("title")?.props["text"] == "Swift.org")
        #expect(screen.first { $0.type == "ProgressView" } == nil)
        #expect(screen.first { $0.type == "TextField" }?.props["text"] == "https://www.swift.org/")
        #expect(screen.button("Reload") != nil)
        #expect(screen.first { $0.type == "WebView" }?.props["page"] == .int(7), "still the same page")

        // The decider keeps the page on the web.
        #expect(engine.delegate.shouldNavigate(engine, url: "https://www.swift.org/install/", kind: 0, isMainFrame: true))
        #expect(!engine.delegate.shouldNavigate(engine, url: "mailto:someone@example.com", kind: 0, isMainFrame: true))
        #expect(renderer.screen?.identified("status")?.props["text"] == "Blocked mailto:someone@example.com")

        // Typing an address and submitting loads it; the buttons drive the page.
        let field = try #require(screen.first { $0.type == "TextField" })
        renderer.send(field, .change, "https://example.com/")
        renderer.send(field, .submit)
        engine.delegate.didChangeHistory(engine, canGoBack: true, canGoForward: false)
        screen = try #require(renderer.screen)
        renderer.send(try #require(screen.button("Back")), .tap)
        renderer.send(try #require(screen.button("Reload")), .tap)
        #expect(engine.calls == ["load https://swift.org/", "load https://example.com/", "back", "reload"])

        // A script's value comes back to the app.
        renderer.send(try #require(screen.button("Count links")), .tap)
        #expect(engine.calls.last == "script 1 document.links.length")
        engine.delegate.didEvaluateJavaScript(engine, request: 1, result: "12", error: nil)
        #expect(renderer.screen?.identified("status")?.props["text"] == "Links: 12")

        // A failed load is shown until the next one starts.
        engine.delegate.didFailNavigation(engine, error: WebError.Code.network.rawValue, message: "Server not found")
        #expect(renderer.screen?.identified("error")?.props["text"] == "Couldn't load the page: Server not found")
        engine.delegate.didChangeLoading(engine, isLoading: true, progress: 0.1)
        #expect(renderer.screen?.identified("error") == nil)
        #expect(WasmTestWebContent.all.count == 1)

        // A host whose app didn't declare network refuses a remote URL.
        engine.delegate.didFailNavigation(engine, error: WebError.Code.notPermitted.rawValue, message: "This app can't use the network")
        #expect(renderer.screen?.identified("error")?.props["text"] == "Couldn't load the page: This app can't use the network")
        // The browser's features. Pages are made with their store and
        // options.
        #expect(engine.made == "store 0 options 0")

        // A link that opens a new window opens a tab, and the host loads
        // the window in it.
        let window = engine.delegate.newPage(engine, url: "https://swift.org/blog/")
        #expect(WasmTestWebContent.all.count == 2)
        let tab = try #require(WasmTestWebContent.all.last)
        #expect(window?.identifier() == tab.id)
        #expect(tab.made == "store 0 options 0", "the opener's configuration")
        #expect(tab.calls.isEmpty)
        screen = try #require(renderer.screen)
        #expect(screen.first { $0.type == "WebView" }?.props["page"] == .int(Int(tab.id)), "the new tab shows")
        tab.delegate.didChangeTitle(tab, title: "Blog")
        screen = try #require(renderer.screen)
        #expect(screen.button("Blog") != nil && screen.button("Swift.org") != nil, "a button for each tab")

        // Find, and the platform's find bar.
        renderer.send(try #require(screen.identified("find")), .change, "swift")
        renderer.send(try #require(screen.button("Find")), .tap)
        #expect(tab.calls.last == "find 1 swift")
        tab.delegate.didFind(tab, request: 1, matchFound: true, count: 3, index: 0)
        #expect(renderer.screen?.identified("status")?.props["text"] == "Found 3 matches")
        renderer.send(try #require(screen.button("Find Bar")), .tap)
        var view = try #require(renderer.screen?.first { $0.type == "WebView" })
        #expect(view.props["findNavigator"] == .bool(true))
        #expect(view.props["backForwardGestures"] == .bool(true))
        renderer.send(view, .change, .bool(false))
        view = try #require(renderer.screen?.first { $0.type == "WebView" })
        #expect(view.props["findNavigator"] == .bool(false), "the user closed it")

        // A download, followed to the end; one the app refuses.
        #expect(tab.delegate.shouldDownload(tab, download: 1, url: "https://swift.org/swift.pkg", suggestedName: "swift.pkg", mimeType: "application/octet-stream", expectedLength: 2048))
        #expect(renderer.screen?.identified("download")?.props["text"] == "swift.pkg: 0 of 2048 bytes")
        tab.delegate.didChangeDownload(tab, download: 1, received: 1024, expected: 2048)
        #expect(renderer.screen?.identified("download")?.props["text"] == "swift.pkg: 1024 of 2048 bytes")
        tab.delegate.didFinishDownload(tab, download: 1, path: "Downloads/swift.pkg")
        #expect(renderer.screen?.identified("download")?.props["text"] == "swift.pkg: done")
        #expect(!tab.delegate.shouldDownload(tab, download: 2, url: "https://example.com/setup.exe", suggestedName: "setup.exe", mimeType: "application/x-msdownload", expectedLength: -1))

        // A site asks for the camera, and the user is asked.
        tab.delegate.didRequestPermission(tab, request: 1, origin: "https://meet.example.com", kinds: 1)
        screen = try #require(renderer.screen)
        #expect(screen.identified("permission")?.props["text"] == "https://meet.example.com wants to use the camera")
        #expect(!tab.calls.contains { $0.hasPrefix("permission") }, "the host waits")
        renderer.send(try #require(screen.button("Allow")), .tap)
        #expect(tab.calls.last == "permission 1 true")
        #expect(renderer.screen?.identified("permission") == nil)

        // The lock, and a picture of the tab.
        tab.delegate.didChangeSecurity(tab, hasOnlySecureContent: true, certificateSummary: "swift.org")
        screen = try #require(renderer.screen)
        #expect(screen.identified("secure") != nil)
        renderer.send(try #require(screen.button("Picture")), .tap)
        #expect(tab.calls.last == "snapshot 2 320.0")
        tab.delegate.didSnapshot(tab, request: 2, png: [0x89, 0x50, 0x4E, 0x47])
        #expect(renderer.screen?.identified("status")?.props["text"] == "Picture: 4 bytes")

        // A private tab, and a message with remote content and scripts off.
        renderer.send(try #require(screen.button("Private Tab")), .tap)
        #expect(WasmTestWebContent.all.last?.made == "store 1 options 0")
        screen = try #require(renderer.screen)
        renderer.send(try #require(screen.button("Message")), .tap)
        let message = try #require(WasmTestWebContent.all.last)
        #expect(message.made == "store 0 options 3")
        #expect(message.calls == ["html"])
        #expect(WasmTestWebContent.all.count == 4)

        // Back to the first tab.
        screen = try #require(renderer.screen)
        renderer.send(try #require(screen.button("Swift.org")), .tap)
        #expect(renderer.screen?.first { $0.type == "WebView" }?.props["page"] == .int(Int(engine.id)))
    }
}
