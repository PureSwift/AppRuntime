/// What an app talks to its pages with, beside `evaluateJavaScript`: scripts
/// that run in every document, messages from a page's scripts, and URL
/// schemes the app answers. The same shapes as PureSwift/WebKit's
/// `CacaoWebKit`.

/// A script a page runs in every document it loads, given in
/// `WebPage.Configuration.userScripts`.
public struct WebUserScript: Equatable, Sendable {

    /// When a script runs.
    public enum InjectionTime: Equatable, Sendable {
        /// Before the document's own scripts, once its element exists.
        case atDocumentStart
        /// Once the document has loaded, before its subresources.
        case atDocumentEnd
    }

    public var source: String

    public var injectionTime: InjectionTime

    /// Whether it runs in the main frame alone, or in every frame.
    public var forMainFrameOnly: Bool

    public init(source: String, injectionTime: InjectionTime, forMainFrameOnly: Bool = true) {
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
    }
}

/// Answers a request for a URL in a scheme the app answers: call `respond`
/// once, at once or later. A request the page stopped wanting, or one whose
/// page went away, ignores its answer.
public typealias WebURLSchemeHandler = (
    _ request: WebURLSchemeRequest,
    _ respond: @escaping (Result<WebURLSchemeResponse, WebError>) -> Void
) -> Void

/// A request a page made for a URL in a scheme its app answers.
public struct WebURLSchemeRequest: Sendable {

    /// The URL, as the page asked for it.
    public var url: String

    /// `GET`, or `POST` for a form or a `fetch` with a body.
    public var method: String

    /// The request's headers, in order.
    public var headers: [(name: String, value: String)]

    /// The request's body; nil when it has none.
    public var body: [UInt8]?

    public init(url: String, method: String = "GET", headers: [(name: String, value: String)] = [], body: [UInt8]? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// The URL's path: what follows the scheme and any authority, without
    /// its query or fragment, such as `/feeds/1.png` for
    /// `app-icon:/feeds/1.png?size=2`.
    public var path: String {
        guard let colon = url.firstIndex(of: ":") else { return "" }
        var rest = url[url.index(after: colon)...]
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            rest = rest[(rest.firstIndex(of: "/") ?? rest.endIndex)...]
        }
        return String(rest.prefix { $0 != "?" && $0 != "#" })
    }
}

/// What a page gets for a URL in a scheme its app answers.
public struct WebURLSchemeResponse: Sendable {

    public var status: Int

    /// The type of what's in `body`, such as `image/png`.
    public var contentType: String?

    /// Other headers. `Content-Type` is sent from `contentType` unless it's
    /// here.
    public var headers: [(name: String, value: String)]

    public var body: [UInt8]

    public init(status: Int = 200, contentType: String?, headers: [(name: String, value: String)] = [], body: [UInt8]) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }
}

extension Array where Element == String {

    /// Names and values in turn, as the contract carries headers.
    init(flattening headers: [(name: String, value: String)]) {
        self = headers.flatMap { [$0.name, $0.value] }
    }

    /// Pairs of names and values, from the contract's; a name left without
    /// a value is dropped.
    var headerPairs: [(name: String, value: String)] {
        stride(from: 0, to: count - 1, by: 2).map { (self[$0], self[$0 + 1]) }
    }
}
