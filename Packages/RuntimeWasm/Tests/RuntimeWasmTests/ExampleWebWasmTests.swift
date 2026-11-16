import Foundation
import Testing
import DynamicUI
import DynamicWebKit
import RuntimeABI
import RuntimeNative
import RuntimeWasm

/// A host's page for the example web app: writes down what it's asked, and
/// keeps the delegate to report back as an engine would.
final class WasmTestWebContent: WebContent {

    nonisolated(unsafe) static var all: [WasmTestWebContent] = []

    let delegate: any WebContentDelegate

    var calls: [String] = []

    init(delegate: any WebContentDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any WebContentDelegate) -> WasmTestWebContent {
        let content = WasmTestWebContent(delegate: delegate)
        all.append(content)
        return content
    }

    func identifier() -> Int32 { 7 }

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
        WasmTestRenderer.last = nil
        WasmTestWebContent.all = []

        let bytes = Array(try Data(contentsOf: Self.exampleWebURL))
        // No capabilities: a web view needs none. Whether its pages reach
        // the network is the host's to enforce.
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        let content = try #require(contracts.first { $0.name == "org.pureswift.web.WebContent" })
        #expect(content.capability == nil)
        #expect(!WasmApp.validate(app.module, runtime: native.runtime, capabilities: []).contains { $0.severity == .error })
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
    }
}
