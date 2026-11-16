import Testing
@testable import DynamicSwiftUI
import DynamicRuntime
import DynamicUI
import DynamicWebKit
import RuntimeNative

/// A host's page: writes down what it's asked, and keeps the delegate to
/// report back as an engine would.
final class TestWebContent: WebContent {

    nonisolated(unsafe) static var all: [TestWebContent] = []

    nonisolated(unsafe) static var live = 0

    nonisolated(unsafe) static var nextIdentifier: Int32 = 1

    static var last: TestWebContent? { all.last }

    let delegate: any WebContentDelegate

    let id: Int32

    var calls: [String] = []

    /// Answers scripts as they arrive, with this JSON.
    var scriptResult: String?

    init(delegate: any WebContentDelegate) {
        self.delegate = delegate
        id = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.live += 1
    }

    deinit {
        Self.live -= 1
    }

    static func make(_ delegate: any WebContentDelegate) -> TestWebContent {
        let content = TestWebContent(delegate: delegate)
        all.append(content)
        return content
    }

    static func reset() {
        all = []
    }

    func identifier() -> Int32 { id }

    func load(_ url: String) { calls.append("load \(url)") }

    func loadHTML(_ html: String, baseURL: String?) { calls.append("html \(html) \(baseURL ?? "-")") }

    func loadResource(_ path: String) { calls.append("resource \(path)") }

    func reload() { calls.append("reload") }

    func stopLoading() { calls.append("stop") }

    func goBack() { calls.append("back") }

    func goForward() { calls.append("forward") }

    func evaluateJavaScript(_ script: String, request: Int32) {
        calls.append("script \(request) \(script)")
        if let scriptResult {
            delegate.didEvaluateJavaScript(self, request: request, result: scriptResult, error: nil)
        }
    }

    /// A page load, as an engine reports one.
    func finishLoading(_ url: String, title: String) {
        delegate.didChangeLoading(self, isLoading: true, progress: 0.1)
        delegate.didChangeURL(self, url: url)
        delegate.didChangeTitle(self, title: title)
        delegate.didChangeLoading(self, isLoading: false, progress: 1)
        delegate.didFinishNavigation(self)
    }
}

/// Records what a view graph sends.
final class WebSink: RenderSink {

    var screen: RenderNode?

    var updates = 0

    func apply(_ tree: RenderNode) {
        screen = tree
        updates += 1
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
        updates += 1
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }
}

struct Browser: View {

    let page: WebPage

    var body: some View {
        VStack {
            Text(page.title)
            WebView(page)
        }
    }
}

struct Viewer: View {

    let address: () -> String?

    var body: some View {
        WebView(url: address())
    }
}

/// Serialized: the tests share the native runtime and the fake host's list
/// of pages, and the frontend keeps the graph being evaluated in a global.
@Suite(.serialized) struct DynamicWebKitTests {

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        WebContentProxy.register(TestWebContent.self, in: native)
        WebContentDelegateProxy.registerInterface(in: native)
        TestWebContent.reset()
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    // MARK: Contracts

    @Test func webContentNeedsNoCapability() {
        let content = WebContentProxy.descriptor
        #expect(content.name == "org.pureswift.web.WebContent")
        #expect(content.capability == nil, "bundled pages need none; the host keeps a page off the network without it")
        #expect(method(content, "make:")?.kind == .constructor)
        #expect(method(content, "identifier")?.signature == Signature("()I"))
        #expect(method(content, "load:")?.signature == Signature("(O)V"))
        #expect(method(content, "loadHTML:baseURL:")?.signature == Signature("(OO)V"))
        #expect(method(content, "loadResource:")?.signature == Signature("(O)V"))
        #expect(method(content, "evaluateJavaScript:request:")?.signature == Signature("(OI)V"))
        #expect(["reload", "stopLoading", "goBack", "goForward"].allSatisfy { method(content, $0)?.signature == Signature("()V") })
        #expect(content.methods.count == 10)
    }

    @Test func delegateAnswersNavigationsSynchronously() {
        let delegate = WebContentDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.web.WebContentDelegate")
        #expect(delegate.kind == .callback)
        #expect(method(delegate, "shouldNavigate:url:kind:isMainFrame:")?.signature == Signature("(OOIZ)Z"))
        #expect(method(delegate, "didChangeLoading:isLoading:progress:")?.signature == Signature("(OZD)V"), "no objects per progress step")
        #expect(method(delegate, "didEvaluateJavaScript:request:result:error:")?.signature == Signature("(OIOO)V"))
        #expect(delegate.methods.count == 8)
        let descriptors = [WebContentProxy.descriptor, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: WebPage

    @Test func aPageIsMadeInTheHostWhenFirstUsed() throws {
        let page = WebPage()
        #expect(TestWebContent.all.isEmpty, "nothing until it's loaded or shown")
        #expect(page.url == nil && page.title == "" && !page.isLoading)

        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        #expect(TestWebContent.all.count == 1)
        #expect(page.identifier == host.id)

        page.load(html: "<p>Hi</p>", baseURL: "https://example.com/base/")
        page.load(html: "<p>Hi</p>")
        page.load(resource: "help/index.html")
        page.reload()
        page.stopLoading()
        page.goBack()
        page.goForward()
        #expect(host.calls == [
            "load https://example.com/",
            "html <p>Hi</p> https://example.com/base/",
            "html <p>Hi</p> -",
            "resource help/index.html",
            "reload", "stop", "back", "forward",
        ])
        #expect(TestWebContent.all.count == 1, "one host page for the page's life")
    }

    @Test func thePageFollowsWhatTheHostReports() throws {
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        var finished = 0
        page.onFinish = { finished += 1 }

        host.delegate.didChangeLoading(host, isLoading: true, progress: 0.25)
        #expect(page.isLoading && page.estimatedProgress == 0.25)
        #expect(page.url == nil, "not until the navigation commits")

        // The server redirected: the page shows where it ended up.
        host.delegate.didChangeURL(host, url: "https://www.example.com/")
        host.delegate.didChangeTitle(host, title: "Example Domain")
        host.delegate.didChangeHistory(host, canGoBack: true, canGoForward: false)
        host.delegate.didChangeLoading(host, isLoading: false, progress: 1)
        host.delegate.didFinishNavigation(host)
        #expect(page.url == "https://www.example.com/")
        #expect(page.title == "Example Domain")
        #expect(page.canGoBack && !page.canGoForward)
        #expect(!page.isLoading && page.estimatedProgress == 1)
        #expect(finished == 1)
        #expect(page.error == nil)
    }

    @Test func aFailureStaysUntilTheNextNavigationStarts() throws {
        let page = WebPage()
        page.load("https://nowhere.invalid/")
        let host = try #require(TestWebContent.last)
        host.delegate.didChangeLoading(host, isLoading: true, progress: 0.1)
        host.delegate.didFailNavigation(host, error: WebError.Code.network.rawValue, message: "Server not found")
        host.delegate.didChangeLoading(host, isLoading: false, progress: 1)
        #expect(page.error == WebError(.network, message: "Server not found"))

        host.delegate.didFailNavigation(host, error: 999, message: "Newer than this guest")
        #expect(page.error?.code == .unknown)

        // What a host answers a remote URL with when the app has no network.
        host.delegate.didFailNavigation(host, error: 7, message: "")
        #expect(page.error == WebError(.notPermitted))

        host.delegate.didChangeLoading(host, isLoading: true, progress: 0.1)
        #expect(page.error == nil)
    }

    @Test func thePageIsObservable() throws {
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { page.title } onChange: { changes += 1 }
        host.delegate.didChangeLoading(host, isLoading: true, progress: 0.5)
        #expect(changes == 0, "only the title was read")
        host.delegate.didChangeTitle(host, title: "Example")
        #expect(changes == 1)

        // A value that didn't change isn't a change.
        _ = withObservationTracking { page.title } onChange: { changes += 1 }
        host.delegate.didChangeTitle(host, title: "Example")
        #expect(changes == 1)
    }

    @Test func theDeciderAllowsOrRefusesNavigations() throws {
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        #expect(host.delegate.shouldNavigate(host, url: "https://elsewhere.test/", kind: 0, isMainFrame: true), "no decider: allowed")

        var asked: [WebNavigation] = []
        page.navigationDecider = { navigation in
            asked.append(navigation)
            return navigation.url.hasPrefix("https://example.com/")
        }
        #expect(host.delegate.shouldNavigate(host, url: "https://example.com/about", kind: 0, isMainFrame: true))
        #expect(!host.delegate.shouldNavigate(host, url: "https://elsewhere.test/", kind: 1, isMainFrame: false))
        #expect(!host.delegate.shouldNavigate(host, url: "tel:5551234", kind: 77, isMainFrame: true))
        #expect(asked == [
            WebNavigation(url: "https://example.com/about", kind: .linkActivated, isMainFrame: true),
            WebNavigation(url: "https://elsewhere.test/", kind: .formSubmitted, isMainFrame: false),
            WebNavigation(url: "tel:5551234", kind: .other, isMainFrame: true),
        ])
    }

    @Test func scriptsAnswerByRequest() throws {
        let page = WebPage()
        var results: [String] = []
        func record(_ label: String) -> (Result<String?, WebError>) -> Void {
            { result in
                switch result {
                case .success(let json): results.append("\(label)=\(json ?? "nil")")
                case .failure(let error): results.append("\(label)!\(error.message)")
                }
            }
        }
        page.evaluateJavaScript("1 + 1", completion: record("a"))
        page.evaluateJavaScript("document.title", completion: record("b"))
        page.evaluateJavaScript("nope()", completion: record("c"))
        page.evaluateJavaScript("console.log('x')", completion: nil)
        let host = try #require(TestWebContent.last)
        #expect(host.calls == ["script 1 1 + 1", "script 2 document.title", "script 3 nope()", "script 4 console.log('x')"])

        // Out of order, as engines may answer.
        host.delegate.didEvaluateJavaScript(host, request: 2, result: "\"Example\"", error: nil)
        host.delegate.didEvaluateJavaScript(host, request: 1, result: "2", error: nil)
        host.delegate.didEvaluateJavaScript(host, request: 3, result: nil, error: "ReferenceError: nope is not defined")
        host.delegate.didEvaluateJavaScript(host, request: 4, result: nil, error: nil)
        host.delegate.didEvaluateJavaScript(host, request: 2, result: "again", error: nil)
        host.delegate.didEvaluateJavaScript(host, request: 99, result: "never asked", error: nil)
        #expect(results == ["b=\"Example\"", "a=2", "c!ReferenceError: nope is not defined"])
    }

    @Test func scriptsCanBeAwaited() async throws {
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        host.scriptResult = "42"
        let value = try await page.evaluateJavaScript("6 * 7")
        #expect(value == "42")
    }

    @Test func releasingThePageDestroysTheHostsPage() throws {
        var cancelled: WebError?
        do {
            let page = WebPage()
            page.load("https://example.com/")
            #expect(TestWebContent.live == 1)
            page.evaluateJavaScript("slow()") { result in
                if case .failure(let error) = result { cancelled = error }
            }
            TestWebContent.reset()
        }
        #expect(TestWebContent.live == 0, "the host's page goes with the guest's")
        #expect(cancelled == WebError(.cancelled), "a script that was still waiting")
        #expect(NativeRuntime.shared.runtime.handleCount == 0)
    }

    // MARK: WebView

    @Test func theNodeNamesThePage() throws {
        let page = WebPage()
        let sink = WebSink()
        let graph = ViewGraph(Browser(page: page), sink: sink)
        graph.update()
        let host = try #require(TestWebContent.last)
        let node = try #require(sink.screen?.first("WebView"))
        #expect(node.props == ["page": .int(Int(host.id))])
        #expect(node.children.isEmpty)
        #expect(host.calls.isEmpty, "showing a page doesn't load anything")

        // The page's state reaches the views around it: the host's report
        // comes in through the runtime, and the update goes out as it returns.
        page.load("https://example.com/")
        host.finishLoading("https://example.com/", title: "Example Domain")
        #expect(!graph.needsUpdate)
        #expect(sink.screen?.first("Text")?.props["text"] == "Example Domain")
        #expect(sink.screen?.first("WebView")?.id == node.id, "the same node: the host keeps its view")
        #expect(TestWebContent.all.count == 1)
    }

    @Test func aURLViewKeepsItsOwnPage() throws {
        var address: String? = "https://example.com/"
        let sink = WebSink()
        let graph = ViewGraph(Viewer(address: { address }), sink: sink)
        graph.update()
        let host = try #require(TestWebContent.last)
        #expect(host.calls == ["load https://example.com/"])
        #expect(sink.screen?.first("WebView")?.props["page"] == .int(Int(host.id)))

        // Updates don't load again, or make another page.
        host.finishLoading("https://example.com/", title: "Example")
        graph.update()
        graph.update()
        #expect(host.calls == ["load https://example.com/"])
        #expect(TestWebContent.all.count == 1)

        // A new URL from the view loads in the same page.
        address = "https://swift.org/"
        graph.update()
        #expect(host.calls == ["load https://example.com/", "load https://swift.org/"])
        #expect(TestWebContent.all.count == 1)

        // No URL: the page stays as it is.
        address = nil
        graph.update()
        #expect(host.calls.count == 2)
    }
}
