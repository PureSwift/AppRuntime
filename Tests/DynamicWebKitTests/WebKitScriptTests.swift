import Testing
@testable import DynamicSwiftUI
import DynamicRuntime
@testable import DynamicWebKit

/// What an app talks to its pages with, through the stand-in engine: user
/// scripts, script messages and URL schemes. Part of `DynamicWebKitTests`,
/// which is serialized.
extension DynamicWebKitTests {

    static let scriptsAndSchemes: WebFeatures = [.userScripts, .scriptMessages, .messageReplies, .urlSchemes]

    // MARK: Contracts

    @Test func theScriptAndSchemeMethodsKeysAndSignatures() {
        let content = WebContentProxy.descriptor
        #expect(content.version == 1)
        #expect(method(content, "make:dataStore:options:schemes:")?.kind == .constructor)
        #expect(method(content, "make:dataStore:options:schemes:")?.signature == Signature("(OIIO)O"))
        #expect(method(content, "addUserScript:atDocumentStart:mainFrameOnly:")?.signature == Signature("(OZZ)V"))
        #expect(method(content, "removeAllUserScripts")?.signature == Signature("()V"))
        #expect(method(content, "addMessageHandler:replies:")?.signature == Signature("(OZ)V"))
        #expect(method(content, "removeMessageHandler:")?.signature == Signature("(O)V"))
        #expect(method(content, "replyToMessage:result:error:")?.signature == Signature("(IOO)V"))
        #expect(method(content, "finishURLSchemeTask:status:contentType:headers:body:")?.signature == Signature("(IIOOO)V"))
        #expect(method(content, "failURLSchemeTask:error:message:")?.signature == Signature("(IIO)V"))

        let delegate = WebContentDelegateProxy.descriptor
        #expect(method(delegate, "didReceiveMessage:name:body:reply:")?.signature == Signature("(OOOI)V"), "0 for a handler that doesn't reply")
        #expect(method(delegate, "startURLSchemeTask:task:url:method:headers:body:")?.signature == Signature("(OIOOOO)V"))
        #expect(method(delegate, "stopURLSchemeTask:task:")?.signature == Signature("(OI)V"))
        let descriptors = [content, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Configuration

    @Test func scriptsAndSchemesTheHostCantRunMakeNoPage() {
        var scripts = WebPage.Configuration()
        scripts.userScripts = [WebUserScript(source: "1", injectionTime: .atDocumentStart)]
        var schemes = WebPage.Configuration()
        schemes.urlSchemeHandlers["app-icon"] = { _, respond in respond(.failure(WebError(.badURL))) }
        #expect(WebPage(configuration: scripts) == nil, "an article without its script")
        #expect(WebPage(configuration: schemes) == nil, "an article without its icons")

        TestWebContent.honored = [.userScripts]
        #expect(WebPage(configuration: scripts) != nil)
        #expect(WebPage(configuration: schemes) == nil)
        TestWebContent.honored = [.urlSchemes]
        #expect(WebPage(configuration: schemes) != nil)
        #expect(TestWebContent.all.isEmpty, "checking makes no page")
    }

    @Test func aPageIsMadeWithItsSchemesAndScripts() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        var configuration = WebPage.Configuration()
        configuration.userScripts = [
            WebUserScript(source: "window.a = 1", injectionTime: .atDocumentStart),
            WebUserScript(source: "window.b = 2", injectionTime: .atDocumentEnd, forMainFrameOnly: false),
        ]
        configuration.urlSchemeHandlers["App-Icon"] = { _, _ in }
        configuration.urlSchemeHandlers["article-image"] = { _, _ in }
        let page = try #require(WebPage(configuration: configuration))
        page.addMessageHandler(named: "note") { _ in }
        page.addMessageHandler(named: "ask") { _, reply in reply(.success(nil)) }
        page.load(html: "<p>Text</p>")
        let host = try #require(TestWebContent.last)
        #expect(host.made == "store 0 options 0 schemes app-icon,article-image", "lowercased, in order, as the page is made")
        #expect(host.calls == [
            "user script window.a = 1 start",
            "user script window.b = 2 end all frames",
            "handler ask replies",
            "handler note",
            "html <p>Text</p> -",
        ], "scripts and handlers before the first load")
    }

    // MARK: Messages

    @Test func messagesReachTheirHandlers() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        let page = WebPage()
        var notes: [String?] = []
        page.addMessageHandler(named: "note") { notes.append($0) }
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        host.delegate.didReceiveMessage(host, name: "note", body: #"{"seen":true}"#, reply: 0)
        host.delegate.didReceiveMessage(host, name: "note", body: nil, reply: 0)
        #expect(notes == [#"{"seen":true}"#, nil])
        // A one-way handler's message that waits anyway is resolved.
        host.delegate.didReceiveMessage(host, name: "note", body: "3", reply: 7)
        #expect(host.calls.last == "reply 7 - -")
        host.delegate.didReceiveMessage(host, name: "other", body: "1", reply: 8)
        #expect(host.calls.last == "reply 8 - nothing answers other")
        host.delegate.didReceiveMessage(host, name: "other", body: "1", reply: 0)
        #expect(host.calls.last == "reply 8 - nothing answers other", "nothing to answer")
    }

    @Test func repliesAreAnsweredOnceNowOrLater() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        let page = WebPage()
        var later: [(Result<String?, WebError>) -> Void] = []
        page.addMessageHandler(named: "now") { body, reply in
            body == "0" ? reply(.failure(WebError(.unknown, message: "no zeros"))) : reply(.success(#"{"echo":\#(body ?? "null")}"#))
        }
        page.addMessageHandler(named: "later") { _, reply in later.append(reply) }
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        host.delegate.didReceiveMessage(host, name: "now", body: "5", reply: 1)
        host.delegate.didReceiveMessage(host, name: "now", body: "0", reply: 2)
        #expect(Array(host.calls.suffix(2)) == [#"reply 1 {"echo":5} -"#, "reply 2 - no zeros"])

        host.delegate.didReceiveMessage(host, name: "later", body: nil, reply: 3)
        #expect(host.calls.last == "reply 2 - no zeros", "waiting")
        let reply = try #require(later.first)
        reply(.success(nil))
        reply(.success("1"))
        #expect(Array(host.calls.suffix(2)) == ["reply 2 - no zeros", "reply 3 - -"], "once, undefined for nil")

        // An error without a message is named by its code.
        host.delegate.didReceiveMessage(host, name: "later", body: nil, reply: 4)
        later[1](.failure(WebError(.notPermitted)))
        #expect(host.calls.last == "reply 4 - notPermitted")
    }

    @Test func aReplyOwedWhenThePageGoesIsRejected() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        var later: [(Result<String?, WebError>) -> Void] = []
        var page: WebPage? = WebPage()
        page?.addMessageHandler(named: "later") { _, reply in later.append(reply) }
        page?.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        host.delegate.didReceiveMessage(host, name: "later", body: nil, reply: 1)
        page = nil
        #expect(host.calls.last == "reply 1 - the page went away")
        later[0](.success("1"))
        #expect(host.calls.last == "reply 1 - the page went away", "answered already")
        host.delegate.didReceiveMessage(host, name: "later", body: nil, reply: 2)
        #expect(host.calls.last == "reply 2 - the page went away")
    }

    @Test func handlersChangeAndGo() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        let page = WebPage()
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        page.addMessageHandler(named: "host") { _ in }
        page.addMessageHandler(named: "host") { _ in }
        page.addMessageHandler(named: "host") { _, reply in reply(.success("1")) }
        page.removeMessageHandler(named: "host")
        page.removeMessageHandler(named: "host")
        #expect(Array(host.calls.dropFirst()) == ["handler host", "remove handler host", "handler host replies", "remove handler host"],
                "added once, and again as the other kind")
        host.delegate.didReceiveMessage(host, name: "host", body: nil, reply: 1)
        #expect(host.calls.last == "reply 1 - nothing answers host")
    }

    @Test func asyncHandlersReply() async throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        let page = WebPage()
        page.addMessageHandler(named: "ask") { body async throws(WebError) -> String? in
            guard body != "0" else {
                throw WebError(.unknown, message: "no zeros")
            }
            return body
        }
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)
        host.delegate.didReceiveMessage(host, name: "ask", body: "5", reply: 1)
        host.delegate.didReceiveMessage(host, name: "ask", body: "0", reply: 2)
        for _ in 0..<100 where host.calls.filter({ $0.hasPrefix("reply") }).count < 2 {
            await Task.yield()
        }
        #expect(host.calls.contains("reply 1 5 -"))
        #expect(host.calls.contains("reply 2 - no zeros"))
    }

    // MARK: URL schemes

    @Test func schemeRequestsReachTheirHandlers() throws {
        TestWebContent.honored = Self.scriptsAndSchemes
        var requests: [WebURLSchemeRequest] = []
        var later: [(Result<WebURLSchemeResponse, WebError>) -> Void] = []
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers["app-icon"] = { request, respond in
            requests.append(request)
            respond(.success(WebURLSchemeResponse(contentType: "image/png", headers: [("Cache-Control", "no-store")], body: [1, 2, 3])))
        }
        configuration.urlSchemeHandlers["app-data"] = { _, respond in later.append(respond) }
        let page = try #require(WebPage(configuration: configuration))
        page.load("https://example.com/")
        let host = try #require(TestWebContent.last)

        host.delegate.startURLSchemeTask(host, task: 1, url: "APP-ICON:/feeds/1.png?size=2", method: "GET", headers: ["Accept", "image/*"], body: nil)
        #expect(host.calls.last == "finish task 1 200 image/png [Cache-Control,no-store] 3 bytes")
        let request = try #require(requests.first)
        #expect(request.path == "/feeds/1.png")
        #expect(request.headers.map(\.name) == ["Accept"] && request.headers.map(\.value) == ["image/*"])
        #expect(request.body == nil && request.method == "GET")

        host.delegate.startURLSchemeTask(host, task: 2, url: "app-data://store/items", method: "POST", headers: [], body: [9])
        host.delegate.startURLSchemeTask(host, task: 3, url: "app-data:/gone", method: "GET", headers: [], body: nil)
        host.delegate.stopURLSchemeTask(host, task: 3)
        later[1](.success(WebURLSchemeResponse(contentType: nil, body: [])))
        #expect(host.calls.last == "finish task 1 200 image/png [Cache-Control,no-store] 3 bytes", "a stopped task's answer does nothing")
        later[0](.failure(WebError(.notPermitted, message: "not for you")))
        later[0](.success(WebURLSchemeResponse(contentType: nil, body: [])))
        #expect(host.calls.last == "fail task 2 \(WebError.Code.notPermitted.rawValue) not for you", "once")

        host.delegate.startURLSchemeTask(host, task: 4, url: "other:/x", method: "GET", headers: [], body: nil)
        #expect(host.calls.last == "fail task 4 \(WebError.Code.badURL.rawValue) nothing answers other:/x")
    }

    @Test func requestsHaveTheirPaths() {
        #expect(WebURLSchemeRequest(url: "app-icon:/feeds/1.png?size=2#top").path == "/feeds/1.png")
        #expect(WebURLSchemeRequest(url: "app-data://store/items/2").path == "/items/2")
        #expect(WebURLSchemeRequest(url: "app-data://store").path == "")
        #expect(WebURLSchemeRequest(url: "app:index.html").path == "index.html")
        #expect(WebURLSchemeRequest(url: "nothing").path == "")
        #expect([String](flattening: [("A", "1"), ("B", "2")]) == ["A", "1", "B", "2"])
        #expect(["A", "1", "B"].headerPairs.map(\.name) == ["A"], "a name without a value is dropped")
    }

    @Test func aDelegateWithoutTheseRefusesThem() throws {
        // The defaults, as a guest built before these were added answers.
        final class Plain: WebContentDelegate {
            func shouldNavigate(_ content: any WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool { true }
            func didChangeURL(_ content: any WebContent, url: String?) { }
            func didChangeTitle(_ content: any WebContent, title: String) { }
            func didChangeLoading(_ content: any WebContent, isLoading: Bool, progress: Double) { }
            func didChangeHistory(_ content: any WebContent, canGoBack: Bool, canGoForward: Bool) { }
            func didFinishNavigation(_ content: any WebContent) { }
            func didFailNavigation(_ content: any WebContent, error: Int32, message: String) { }
            func didEvaluateJavaScript(_ content: any WebContent, request: Int32, result: String?, error: String?) { }
        }
        let host = TestWebContent.make(Plain())
        host.delegate.didReceiveMessage(host, name: "note", body: nil, reply: 0)
        host.delegate.didReceiveMessage(host, name: "ask", body: nil, reply: 1)
        host.delegate.startURLSchemeTask(host, task: 1, url: "app:/x", method: "GET", headers: [], body: nil)
        host.delegate.stopURLSchemeTask(host, task: 1)
        #expect(host.calls == ["reply 1 - nothing answers ask", "fail task 1 \(WebError.Code.badURL.rawValue) nothing answers app:/x"])
    }
}
