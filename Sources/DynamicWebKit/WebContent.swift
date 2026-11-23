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
///
/// Version 2 added what a browser and a mail reader need: data stores,
/// pages without remote content or scripts, new windows, downloads, find,
/// permissions, snapshots and removing data. Each has a default here that
/// does nothing, and a host says which it honors in `features()`. Only a
/// page made by `make(_:dataStore:options:)` has a delegate that takes
/// version 2's events.
@DynamicRuntime("org.pureswift.web.WebContent", version: 2)
public protocol WebContent: AnyObject {

    /// A page whose delegate takes only version 1's events.
    static func make(_ delegate: WebContentDelegate) -> Self

    /// A `WebFeatures` bit set of what this host honors. Since version 2.
    static func features() -> Int32

    /// A page whose delegate takes version 2's events too. `dataStore` 0 is
    /// the app's default store; another number names a non-persistent
    /// store, made when a page first names it and let go when none does.
    /// `options` is `WebPageOptions` bits. Since version 2.
    static func make(_ delegate: WebContentDelegate, dataStore: Int32, options: Int32) -> Self

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

    // MARK: Since version 2

    /// Empty is the engine's own.
    func setCustomUserAgent(_ userAgent: String)

    /// 1 is 100%.
    func setPageZoom(_ zoom: Double)

    /// Highlights and scrolls to the next match. Answered by `didFind` for
    /// `request`.
    func find(_ text: String, backwards: Bool, caseSensitive: Bool, request: Int32)

    /// Removes find's highlight.
    func clearFind()

    /// Stops a download `shouldDownload` accepted. The host reports nothing
    /// more about it.
    func cancelDownload(_ download: Int32)

    /// The answer to `didRequestPermission`.
    func answerPermission(_ request: Int32, granted: Bool)

    /// The page as it's drawn now, as PNG bytes `width` points wide.
    /// Answered by `didSnapshot`, or `didFailRequest`.
    func snapshot(_ width: Double, request: Int32)

    /// Removes cookies, storage, caches and the rest of what sites kept in
    /// this page's data store since `since`, seconds since 1970, for every
    /// page of the store. Answered by `didCompleteRequest`, or
    /// `didFailRequest`.
    func removeData(since: Double, request: Int32)
}

/// What a host built before version 2 does: nothing. A host that honors
/// one of these says so in `features()`.
public extension WebContent {

    static func features() -> Int32 { 0 }

    static func make(_ delegate: WebContentDelegate, dataStore: Int32, options: Int32) -> Self {
        make(delegate)
    }

    func setCustomUserAgent(_ userAgent: String) { }

    func setPageZoom(_ zoom: Double) { }

    func find(_ text: String, backwards: Bool, caseSensitive: Bool, request: Int32) { }

    func clearFind() { }

    func cancelDownload(_ download: Int32) { }

    func answerPermission(_ request: Int32, granted: Bool) { }

    func snapshot(_ width: Double, request: Int32) { }

    func removeData(since: Double, request: Int32) { }
}
