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
}
