import Testing
@testable import DynamicSwiftUI
import DynamicFiles
import DynamicRuntime
import DynamicUI
@testable import DynamicWebKit
import RuntimeNative

/// `WebContent` version 2 through the stand-in engine. Part of
/// `DynamicWebKitTests`, which is serialized.
extension DynamicWebKitTests {

    static let everything = WebFeatures(rawValue: 4095)

    // MARK: Contracts

    @Test func version2AddsMethodsNotContracts() {
        let content = WebContentProxy.descriptor
        #expect(content.version == 2)
        #expect(method(content, "features")?.kind == .static)
        #expect(method(content, "features")?.signature == Signature("()I"))
        #expect(method(content, "make:dataStore:options:")?.kind == .constructor)
        #expect(method(content, "make:dataStore:options:")?.signature == Signature("(OII)O"))
        #expect(method(content, "find:backwards:caseSensitive:request:")?.signature == Signature("(OZZI)V"))
        #expect(method(content, "answerPermission:granted:")?.signature == Signature("(IZ)V"))
        #expect(method(content, "snapshot:request:")?.signature == Signature("(DI)V"))
        #expect(method(content, "removeData:request:")?.signature == Signature("(DI)V"), "a first label isn't in a key")

        let delegate = WebContentDelegateProxy.descriptor
        #expect(delegate.version == 2)
        #expect(method(delegate, "newPage:url:")?.signature == Signature("(OO)O"), "the guest's page for the window, or nil")
        #expect(method(delegate, "shouldDownload:download:url:suggestedName:mimeType:expectedLength:")?.signature == Signature("(OIOOOJ)Z"), "answered while the host waits")
        #expect(method(delegate, "didChangeDownload:download:received:expected:")?.signature == Signature("(OIJJ)V"), "no objects per progress step")
        #expect(method(delegate, "didFind:request:matchFound:count:index:")?.signature == Signature("(OIZII)V"))
        #expect(method(delegate, "didSnapshot:request:png:")?.signature == Signature("(OIO)V"))
        let descriptors = [content, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Configuration

    @Test func aConfigurationTheHostCantHonorMakesNoPage() {
        // A host with only the defaults: features() is 0.
        #expect(WebPage.hostFeatures == [])
        #expect(WebPage(configuration: WebPage.Configuration()) != nil, "the default needs nothing")
        #expect(WebPage(configuration: WebPage.Configuration(allowsFileUploads: false)) != nil, "no feature to say for uploads")
        #expect(WebPage(configuration: WebPage.Configuration(websiteDataStore: .nonPersistent())) == nil, "a private tab that kept its cookies")
        #expect(WebPage(configuration: WebPage.Configuration(loadsRemoteContent: false)) == nil, "a message that loaded remote images")
        #expect(WebPage(configuration: WebPage.Configuration(allowsJavaScript: false)) == nil)

        TestWebContent.honored = [.nonPersistentStores, .remoteContentOff]
        #expect(WebPage(configuration: WebPage.Configuration(websiteDataStore: .nonPersistent(), loadsRemoteContent: false)) != nil)
        #expect(WebPage(configuration: WebPage.Configuration(allowsJavaScript: false)) == nil)
        #expect(TestWebContent.all.isEmpty, "checking makes no page")
    }

    @Test func pagesAreMadeByTheVersion2Constructor() throws {
        TestWebContent.honored = Self.everything
        let plain = WebPage()
        plain.load("https://example.com/")
        #expect(TestWebContent.last?.made == "store 0 options 0", "so the host knows the delegate takes version 2's events")

        let store = WebsiteDataStore.nonPersistent()
        #expect(!store.isPersistent && WebsiteDataStore.default.isPersistent)
        #expect(store != WebsiteDataStore.nonPersistent(), "each is a store of its own")
        let configuration = WebPage.Configuration(websiteDataStore: store, loadsRemoteContent: false, allowsJavaScript: false, allowsFileUploads: false)
        let first = try #require(WebPage(configuration: configuration))
        let second = try #require(WebPage(configuration: configuration))
        _ = first.identifier
        let firstHost = try #require(TestWebContent.last)
        _ = second.identifier
        let secondHost = try #require(TestWebContent.last)
        #expect(firstHost.made == "store \(store.identifier) options 7")
        #expect(secondHost.made == firstHost.made, "pages with one store share it")
        #expect(first.configuration == configuration)
    }

    @Test func theUserAgentAndZoomGoToTheHost() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.customUserAgent = "ExampleBrowser/1.0"
        page.customUserAgent = "ExampleBrowser/1.0"
        page.pageZoom = 1.25
        page.customUserAgent = nil
        let host = try #require(TestWebContent.last)
        #expect(host.calls == ["user agent ExampleBrowser/1.0", "zoom 1.25", "user agent "])
    }

    // MARK: New pages

    @Test func aNewWindowOpensInThePageTheHandlerMakes() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        #expect(host.delegate.newPage(host, url: "https://example.com/a") == nil, "no handler: the same page")

        var tabs: [WebPage] = []
        var asked: [String] = []
        page.newPageHandler = { url in
            asked.append(url)
            let tab = WebPage(configuration: page.configuration)
            if let tab { tabs.append(tab) }
            return tab
        }
        var madeDuringTheCall = 0
        TestWebContent.onMake = { _ in madeDuringTheCall += 1 }
        let window = host.delegate.newPage(host, url: "https://example.com/b")
        let tabHost = try #require(TestWebContent.last)
        #expect(window?.identifier() == tabHost.id, "the tab's host page, to load the window in")
        let proxy = try #require(window as? DynamicObject)
        #expect(NativeRuntime.shared.swiftObject(for: proxy) === tabHost, "a host finds its own page behind the proxy")
        #expect(madeDuringTheCall == 1, "made while the host waits, with the engine's settings")
        #expect(asked == ["https://example.com/b"])
        #expect(tabs.count == 1 && tabs[0].identifier == tabHost.id)

        // A page made before the call already has a view: the same page.
        let earlier = WebPage()
        _ = earlier.identifier
        page.newPageHandler = { _ in earlier }
        #expect(host.delegate.newPage(host, url: "https://example.com/c") == nil)
        page.newPageHandler = { _ in page }
        #expect(host.delegate.newPage(host, url: "https://example.com/d") == nil)
        page.newPageHandler = { _ in nil }
        #expect(host.delegate.newPage(host, url: "https://example.com/e") == nil)
    }

    // MARK: Downloads

    @Test func downloadsAreAskedAboutAndFollowed() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        #expect(!host.delegate.shouldDownload(host, download: 1, url: "https://example.com/a.pdf", suggestedName: "a.pdf", mimeType: "application/pdf", expectedLength: 2048), "no decider: refused, as in version 1")

        var asked: [WebDownloadRequest] = []
        var started: [WebDownload] = []
        page.downloadDecider = { request in
            asked.append(request)
            return request.mimeType != "application/x-msdownload"
        }
        page.onDownload = { started.append($0) }
        #expect(!host.delegate.shouldDownload(host, download: 2, url: "https://example.com/setup.exe", suggestedName: "setup.exe", mimeType: "application/x-msdownload", expectedLength: -1))
        #expect(host.delegate.shouldDownload(host, download: 3, url: "https://example.com/a.pdf", suggestedName: "a.pdf", mimeType: "application/pdf", expectedLength: -1))
        #expect(asked.map(\.suggestedName) == ["setup.exe", "a.pdf"])
        #expect(asked[0].expectedLength == nil, "-1: the server didn't say")
        let download = try #require(started.first)
        #expect(started.count == 1)
        #expect(download.request.url == "https://example.com/a.pdf")
        #expect(download.expectedLength == nil && download.bytesReceived == 0 && !download.isFinished)

        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { download.bytesReceived } onChange: { changes += 1 }
        host.delegate.didChangeDownload(host, download: 3, received: 1024, expected: 2048)
        #expect(changes == 1)
        #expect(download.bytesReceived == 1024 && download.expectedLength == 2048)

        host.delegate.didFinishDownload(host, download: 3, path: "Downloads/a.pdf")
        #expect(download.file == FilePath(.caches, "Downloads/a.pdf"))
        #expect(download.isFinished && download.error == nil)
        host.delegate.didFailDownload(host, download: 3, error: WebError.Code.network.rawValue, message: "late")
        #expect(download.error == nil, "done is done")

        // Another, cancelled by the app: the host is told, and says no more.
        #expect(host.delegate.shouldDownload(host, download: 4, url: "https://example.com/b.zip", suggestedName: "b.zip", mimeType: "application/zip", expectedLength: 10))
        let second = try #require(started.last)
        #expect(second.expectedLength == 10)
        second.cancel()
        #expect(host.calls.last == "cancel download 4")
        #expect(second.error == WebError(.cancelled) && second.isFinished)
        host.delegate.didChangeDownload(host, download: 4, received: 5, expected: 10)
        #expect(second.bytesReceived == 0)

        // A failure.
        #expect(host.delegate.shouldDownload(host, download: 5, url: "https://example.com/c", suggestedName: "c", mimeType: "text/csv", expectedLength: -1))
        host.delegate.didFailDownload(host, download: 5, error: WebError.Code.network.rawValue, message: "Lost connection")
        #expect(started.last?.error == WebError(.network, message: "Lost connection"))
    }

    // MARK: Find, security, permissions

    @Test func findNeedsTheFeature() async throws {
        let page = WebPage()
        page.load("https://example.com/")
        await #expect(throws: WebError(.unavailable)) { try await page.find("swift") }
        #expect(TestWebContent.last?.calls == ["load https://example.com/"], "nothing asked of a host without find")
    }

    @Test func findAnswersByRequest() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        var results: [Result<WebFindResult, WebError>] = []
        page.find("swift") { results.append($0) }
        page.find("Swift", backwards: true, caseSensitive: true) { results.append($0) }
        page.find("nothing") { results.append($0) }
        #expect(host.calls.suffix(3) == ["find 1 swift", "find 2 Swift backwards case", "find 3 nothing"])
        host.delegate.didFind(host, request: 2, matchFound: true, count: -1, index: -1)
        host.delegate.didFind(host, request: 1, matchFound: true, count: 12, index: 0)
        host.delegate.didFailRequest(host, request: 3, error: 99, message: "Newer")
        host.delegate.didFind(host, request: 1, matchFound: false, count: 0, index: -1)
        #expect(results == [
            .success(WebFindResult(matchFound: true)),
            .success(WebFindResult(matchFound: true, matchCount: 12, matchIndex: 0)),
            .failure(WebError(.unknown, message: "Newer")),
        ])
        page.clearFind()
        #expect(host.calls.last == "clear find")
    }

    @Test func theSecurityStateIsObservable() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        #expect(!page.hasOnlySecureContent && page.certificateSummary == nil)
        nonisolated(unsafe) var changes = 0
        _ = withObservationTracking { page.hasOnlySecureContent } onChange: { changes += 1 }
        host.delegate.didChangeSecurity(host, hasOnlySecureContent: true, certificateSummary: "example.com")
        #expect(changes == 1)
        #expect(page.hasOnlySecureContent && page.certificateSummary == "example.com")
        host.delegate.didChangeSecurity(host, hasOnlySecureContent: false, certificateSummary: "")
        #expect(!page.hasOnlySecureContent && page.certificateSummary == nil, "empty: no certificate")
    }

    @Test func permissionsAreTheAppsToAnswer() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        page.load("https://meet.example.com/")
        let host = try #require(TestWebContent.last)
        host.delegate.didRequestPermission(host, request: 1, origin: "https://meet.example.com", kinds: 3)
        #expect(host.calls.last == "permission 1 false", "no handler: refused, as in version 1")

        var pending: [WebPermissionRequest] = []
        page.onPermissionRequest = { pending.append($0) }
        host.delegate.didRequestPermission(host, request: 2, origin: "https://meet.example.com", kinds: 3)
        #expect(host.calls.last == "permission 1 false", "the host waits for the answer")
        let request = try #require(pending.first)
        #expect(request.origin == "https://meet.example.com")
        #expect(request.kinds == [.camera, .microphone])
        request.grant()
        request.deny()
        #expect(host.calls.last == "permission 2 true")
        #expect(host.calls.filter { $0.hasPrefix("permission 2") }.count == 1, "the first answer counts")

        // A request let go unanswered is refused.
        host.delegate.didRequestPermission(host, request: 3, origin: "https://maps.example.com", kinds: 4)
        pending = []
        #expect(host.calls.last == "permission 3 false")
    }

    // MARK: Snapshots and data

    @Test func snapshotsArePNGBytes() async throws {
        let page = WebPage()
        page.load("https://example.com/")
        await #expect(throws: WebError(.unavailable)) { try await page.snapshot(width: 320) }

        TestWebContent.honored = Self.everything
        let host = try #require(TestWebContent.last)
        var results: [Result<[UInt8], WebError>] = []
        page.snapshot(width: 320) { results.append($0) }
        page.snapshot(width: 160) { results.append($0) }
        #expect(host.calls.suffix(2) == ["snapshot 1 320.0", "snapshot 2 160.0"])
        host.delegate.didSnapshot(host, request: 1, png: [0x89, 0x50, 0x4E, 0x47])
        host.delegate.didFailRequest(host, request: 2, error: WebError.Code.unavailable.rawValue, message: "Nothing drawn yet")
        #expect(results == [.success([0x89, 0x50, 0x4E, 0x47]), .failure(WebError(.unavailable, message: "Nothing drawn yet"))])
    }

    @Test func removingDataAsksAPageOfTheStore() throws {
        var results: [Result<Void, WebError>] = []
        WebsiteDataStore.default.removeData { results.append($0) }
        #expect(results.count == 1 && TestWebContent.all.isEmpty, "unavailable, and nothing made")
        if case .failure(let error) = results[0] { #expect(error.code == .unavailable) }

        TestWebContent.honored = Self.everything
        let store = WebsiteDataStore.nonPersistent()
        store.removeData(since: 1_700_000_000) { results.append($0) }
        let host = try #require(TestWebContent.last)
        #expect(host.made == "store \(store.identifier) options 0")
        #expect(host.calls == ["remove data 1 1700000000.0"])
        TestWebContent.reset()
        #expect(TestWebContent.live == 1, "kept until the host answers")
        host.delegate.didCompleteRequest(host, request: 1)
        #expect(results.count == 2)
        if case .failure = results[1] { Issue.record("removing data failed") }
    }

    @Test func aReleasedPageCancelsWhatsWaiting() throws {
        TestWebContent.honored = Self.everything
        var outcomes: [String] = []
        var download: WebDownload?
        do {
            let page = WebPage()
            page.load("https://example.com/")
            let host = try #require(TestWebContent.last)
            page.find("x") { if case .failure(let error) = $0 { outcomes.append("find \(error.code)") } }
            page.snapshot(width: 10) { if case .failure(let error) = $0 { outcomes.append("snapshot \(error.code)") } }
            page.downloadDecider = { _ in true }
            #expect(host.delegate.shouldDownload(host, download: 9, url: "https://example.com/z", suggestedName: "z", mimeType: "application/zip", expectedLength: -1))
            page.onDownload = nil
            download = nil
            TestWebContent.reset()
            _ = page
        }
        #expect(outcomes == ["find cancelled", "snapshot cancelled"])
        #expect(TestWebContent.live == 0)
        _ = download
    }

    // MARK: WebView

    @Test func theFindBarAndGesturesAreProps() throws {
        TestWebContent.honored = Self.everything
        let page = WebPage()
        let finding = FindingState()
        let sink = WebSink()
        let graph = ViewGraph(Finder(page: page, state: finding), sink: sink)
        graph.update()
        let host = try #require(TestWebContent.last)
        var node = try #require(sink.screen?.first("WebView"))
        #expect(node.props == [
            "page": .int(Int(host.id)),
            "findNavigator": .bool(false),
            "backForwardGestures": .bool(true),
            "magnificationGestures": .bool(false),
        ])

        finding.isPresented = true
        graph.update()
        node = try #require(sink.screen?.first("WebView"))
        #expect(node.props["findNavigator"] == .bool(true))

        // The user closed the bar.
        #expect(graph.handle(node.id, kind: .change, payload: .bool(false)))
        #expect(!finding.isPresented)
        #expect(graph.handle(node.id, kind: .change, payload: .bool(true)))
        #expect(!finding.isPresented, "only the host closes it")
    }
}

/// Plain, not `@Observable`: the test updates the graph itself.
final class FindingState {
    var isPresented = false
}

struct Finder: View {

    let page: WebPage

    let state: FindingState

    var body: some View {
        WebView(page)
            .findNavigator(isPresented: Binding(get: { state.isPresented }, set: { state.isPresented = $0 }))
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewMagnificationGestures(.disabled)
    }
}
