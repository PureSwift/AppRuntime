import DynamicRuntime

/// Receives a `WebContent`'s state and questions on the main thread.
///
/// A new page has no URL, an empty title, and isn't loading; the delegate
/// hears every change from there.
@DynamicCallback("org.pureswift.web.WebContentDelegate")
public protocol WebContentDelegate: AnyObject {

    /// Whether the page may go to `url`. The host waits for the answer:
    /// it's asked before every navigation the page or the user starts, and
    /// isn't asked for `load`, `loadHTML` or `loadResource` themselves.
    /// `kind` is a `WebNavigationKind` raw value.
    func shouldNavigate(_ content: WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool

    /// The main frame shows another URL: a navigation committed, a redirect
    /// was followed, or the page changed it with the History API.
    func didChangeURL(_ content: WebContent, url: String?)

    func didChangeTitle(_ content: WebContent, title: String)

    /// Loading started, went on, or ended. `progress` is 0…1, and 1 once
    /// loading ends.
    func didChangeLoading(_ content: WebContent, isLoading: Bool, progress: Double)

    func didChangeHistory(_ content: WebContent, canGoBack: Bool, canGoForward: Bool)

    /// The main frame finished loading.
    func didFinishNavigation(_ content: WebContent)

    /// The main frame's navigation failed. `error` is a `WebError.Code` raw
    /// value, and `message` the engine's own description.
    func didFailNavigation(_ content: WebContent, error: Int32, message: String)

    /// The outcome of `evaluateJavaScript` for `request`: the script's
    /// value as JSON text (`nil` for `undefined` and values JSON can't
    /// hold), or the exception's message in `error`.
    func didEvaluateJavaScript(_ content: WebContent, request: Int32, result: String?, error: String?)

    // MARK: A browser's and a mail reader's

    /// The page opens a new window (`target="_blank"`, `window.open`),
    /// after `shouldNavigate` agreed. Returns a page made during this call,
    /// which the host makes with the engine's settings for the window and
    /// loads it in, or nil to load it in this page.
    func newPage(_ content: WebContent, url: String) -> WebContent?

    /// Whether to download what `url` answered. The host waits for the
    /// answer. `download` names it from then on; `expectedLength` is -1
    /// when the server doesn't say.
    func shouldDownload(_ content: WebContent, download: Int32, url: String, suggestedName: String, mimeType: String, expectedLength: Int64) -> Bool

    /// No more than ten times a second.
    func didChangeDownload(_ content: WebContent, download: Int32, received: Int64, expected: Int64)

    /// Done: the file is at `path` in the app's caches, under `Downloads/`.
    func didFinishDownload(_ content: WebContent, download: Int32, path: String)

    /// `error` is a `WebError.Code` raw value.
    func didFailDownload(_ content: WebContent, download: Int32, error: Int32, message: String)

    /// The outcome of `find` for `request`. `count` is how many matches,
    /// and `index` which one is highlighted, from 0; both -1 where the
    /// engine doesn't say.
    func didFind(_ content: WebContent, request: Int32, matchFound: Bool, count: Int32, index: Int32)

    /// After each main-frame navigation commits, and when the page loads
    /// something insecure. `certificateSummary` is who the certificate was
    /// issued to, or empty without one.
    func didChangeSecurity(_ content: WebContent, hasOnlySecureContent: Bool, certificateSummary: String)

    /// A site asks for `kinds`, `WebPermissionKinds` bits, as `origin`.
    /// Answer with `answerPermission`.
    func didRequestPermission(_ content: WebContent, request: Int32, origin: String, kinds: Int32)

    func didSnapshot(_ content: WebContent, request: Int32, png: [UInt8])

    /// A request that has no other answer, such as `removeData`, is done.
    func didCompleteRequest(_ content: WebContent, request: Int32)

    /// `find`, `snapshot` or `removeData` failed. `error` is a
    /// `WebError.Code` raw value.
    func didFailRequest(_ content: WebContent, request: Int32, error: Int32, message: String)
}

/// What a delegate that doesn't implement these answers: a new window loads
/// in the same page, downloads and permissions are refused, and the rest is
/// ignored.
public extension WebContentDelegate {

    func newPage(_ content: WebContent, url: String) -> WebContent? { nil }

    func shouldDownload(_ content: WebContent, download: Int32, url: String, suggestedName: String, mimeType: String, expectedLength: Int64) -> Bool { false }

    func didChangeDownload(_ content: WebContent, download: Int32, received: Int64, expected: Int64) { }

    func didFinishDownload(_ content: WebContent, download: Int32, path: String) { }

    func didFailDownload(_ content: WebContent, download: Int32, error: Int32, message: String) { }

    func didFind(_ content: WebContent, request: Int32, matchFound: Bool, count: Int32, index: Int32) { }

    func didChangeSecurity(_ content: WebContent, hasOnlySecureContent: Bool, certificateSummary: String) { }

    func didRequestPermission(_ content: WebContent, request: Int32, origin: String, kinds: Int32) {
        content.answerPermission(request, granted: false)
    }

    func didSnapshot(_ content: WebContent, request: Int32, png: [UInt8]) { }

    func didCompleteRequest(_ content: WebContent, request: Int32) { }

    func didFailRequest(_ content: WebContent, request: Int32, error: Int32, message: String) { }
}
