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
        /// The URL is remote, and the app's manifest doesn't declare the
        /// `network` capability.
        case notPermitted = 7
        /// This host doesn't do what was asked: it doesn't say so in
        /// `WebPage.hostFeatures`. Hosts send it for a snapshot of a page
        /// that has nothing drawn yet.
        case unavailable = 8
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

/// What a host does of `WebContent` version 2. A host built before it does
/// none of it.
public struct WebFeatures: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// `WebsiteDataStore.nonPersistent()` stores.
    public static let nonPersistentStores = WebFeatures(rawValue: 1)
    /// `loadsRemoteContent: false`.
    public static let remoteContentOff = WebFeatures(rawValue: 2)
    /// `allowsJavaScript: false`.
    public static let pageScriptsOff = WebFeatures(rawValue: 4)
    /// `WebPage.newPageHandler`.
    public static let newPages = WebFeatures(rawValue: 8)
    public static let downloads = WebFeatures(rawValue: 16)
    public static let find = WebFeatures(rawValue: 32)
    /// The platform's find bar, `findNavigator(isPresented:)`.
    public static let findNavigator = WebFeatures(rawValue: 64)
    public static let permissions = WebFeatures(rawValue: 128)
    public static let snapshots = WebFeatures(rawValue: 256)
    /// `WebsiteDataStore.removeData(since:)`.
    public static let removingData = WebFeatures(rawValue: 512)
    /// `hasOnlySecureContent` and `certificateSummary`.
    public static let security = WebFeatures(rawValue: 1024)
    /// `customUserAgent` and `pageZoom`.
    public static let userAgentAndZoom = WebFeatures(rawValue: 2048)
}

/// How a page is made, for `WebContent.make(_:dataStore:options:)`.
struct WebPageOptions: OptionSet {

    let rawValue: Int32

    static let noRemoteContent = WebPageOptions(rawValue: 1)
    static let noPageScripts = WebPageOptions(rawValue: 2)
    static let noUploads = WebPageOptions(rawValue: 4)
}

/// What a site asks to use.
public struct WebPermissionKinds: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let camera = WebPermissionKinds(rawValue: 1)
    public static let microphone = WebPermissionKinds(rawValue: 2)
    public static let location = WebPermissionKinds(rawValue: 4)
}

/// A response the page can't show, which it may download, for
/// `WebPage.downloadDecider`.
public struct WebDownloadRequest: Equatable, Sendable {

    public var url: String

    /// The server's, or the URL's last component.
    public var suggestedName: String

    public var mimeType: String

    /// `nil` when the server doesn't say.
    public var expectedLength: Int64?

    public init(url: String, suggestedName: String, mimeType: String, expectedLength: Int64?) {
        self.url = url
        self.suggestedName = suggestedName
        self.mimeType = mimeType
        self.expectedLength = expectedLength
    }
}

/// What `WebPage.find` found.
public struct WebFindResult: Equatable, Sendable {

    public var matchFound: Bool

    /// How many matches there are, where the engine says. Apple's engines
    /// don't.
    public var matchCount: Int?

    /// Which match is highlighted, from 0, where the engine says.
    public var matchIndex: Int?

    public init(matchFound: Bool, matchCount: Int? = nil, matchIndex: Int? = nil) {
        self.matchFound = matchFound
        self.matchCount = matchCount
        self.matchIndex = matchIndex
    }
}
