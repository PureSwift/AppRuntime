import DynamicRuntime

/// A page of web content the host renders: a browser engine's web view,
/// without its place on screen.
///
/// A `WebView` node in the render IR says where a page is shown, by its
/// `identifier()`. A page loads whether or not it's on screen. App code
/// uses `WebPage`, which wraps this contract.
///
/// It needs no capability: a page can show an HTML string or a file from
/// the app bundle. Reaching the network does: without `network` in the
/// app's manifest, the host loads nothing remote, and a navigation to a
/// remote URL fails with `WebError.Code.notPermitted`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `WKWebView` |
/// | Android | `android.webkit.WebView` |
/// | Linux | WPE WebKit (`WebKitWebView`), drawn into the player's scene |
/// | Browser | an `<iframe>` |
@DynamicRuntime("org.pureswift.web.WebContent")
public protocol WebContent: AnyObject {

    static func make(_ delegate: WebContentDelegate) -> Self

    /// What a `WebView` node carries to say which page it shows. Unique
    /// among the app's pages while this one is alive.
    func identifier() -> Int32

    // MARK: Loading

    /// Starts loading `url`. Progress and failure arrive through the
    /// delegate. A remote URL needs the `network` capability.
    func load(_ url: String)

    /// Shows `html`. Relative URLs in it resolve against `baseURL`; without
    /// one the page has no origin and can't load relative resources.
    func loadHTML(_ html: String, baseURL: String?)

    /// Loads a file from the app bundle's resources, by its path there, as
    /// `Bundle` finds resources. Files beside it are readable to the page.
    func loadResource(_ path: String)

    func reload()

    func stopLoading()

    /// Does nothing at the end of the history.
    func goBack()

    func goForward()

    // MARK: Scripts

    /// Evaluates `script` in the page's main frame. The result arrives as
    /// `didEvaluateJavaScript` with the same `request`.
    func evaluateJavaScript(_ script: String, request: Int32)
}
