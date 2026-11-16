/// Guest-side names for what the web contracts carry.

/// What started a navigation.
public enum WebNavigationKind: Int32, Sendable {
    /// The user followed a link.
    case linkActivated = 0
    case formSubmitted = 1
    /// Back or forward in the history.
    case backForward = 2
    case reload = 3
    /// A script, a redirect, or anything else.
    case other = 4
}

/// A navigation a page is about to make, for `WebPage.navigationDecider`.
public struct WebNavigation: Equatable, Sendable {

    public var url: String

    public var kind: WebNavigationKind

    /// `false` for a frame inside the page.
    public var isMainFrame: Bool

    public init(url: String, kind: WebNavigationKind, isMainFrame: Bool) {
        self.url = url
        self.kind = kind
        self.isMainFrame = isMainFrame
    }
}

/// Why a navigation or a script failed.
public struct WebError: Error, Equatable, Sendable {

    public enum Code: Int32, Sendable {
        case unknown = 0
        /// Guest-side: the task waiting for a script was cancelled, or the
        /// page was released first. Hosts never send it.
        case cancelled = 1
        /// No connection, or the server couldn't be found or reached.
        case network = 2
        case timedOut = 3
        /// The connection wasn't secure enough to use: a bad certificate,
        /// or plain HTTP where the platform forbids it.
        case security = 4
        /// A malformed URL, a scheme the engine doesn't handle, or a
        /// resource that isn't in the bundle.
        case badURL = 5
        /// A script threw.
        case javaScript = 6
    }

    public var code: Code

    /// The engine's description, for logs. It isn't localized the same way
    /// on every host.
    public var message: String

    public init(_ code: Code, message: String = "") {
        self.code = code
        self.message = message
    }
}
