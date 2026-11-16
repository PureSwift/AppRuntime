import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A page of web content: what it shows, how far it has loaded, and where
/// it can go. Show it with `WebView(page)`.
///
/// It's observable, so a view that reads `title` or `estimatedProgress`
/// updates as the page loads:
///
/// ```swift
/// let page = WebPage()
/// page.load("https://swift.org")
///
/// // In a view's body:
/// if page.isLoading {
///     ProgressView(value: page.estimatedProgress)
/// }
/// WebView(page)
/// ```
///
/// The page lives in the host (`WebContent`), which is made the first time
/// the page is loaded or shown. It keeps loading while it's off screen, and
/// is destroyed when the `WebPage` is released.
public final class WebPage: Observable {

    // MARK: State

    /// The main frame's URL, once a navigation has committed.
    public var url: String? {
        registrar.access(self, propertyIndex: 0)
        return values.url
    }

    public var title: String {
        registrar.access(self, propertyIndex: 1)
        return values.title
    }

    public var isLoading: Bool {
        registrar.access(self, propertyIndex: 2)
        return values.isLoading
    }

    /// 0…1.
    public var estimatedProgress: Double {
        registrar.access(self, propertyIndex: 3)
        return values.estimatedProgress
    }

    public var canGoBack: Bool {
        registrar.access(self, propertyIndex: 4)
        return values.canGoBack
    }

    public var canGoForward: Bool {
        registrar.access(self, propertyIndex: 5)
        return values.canGoForward
    }

    /// Why the last navigation failed; `nil` again once another starts.
    public var error: WebError? {
        registrar.access(self, propertyIndex: 6)
        return values.error
    }

    /// Decides whether the page may follow a navigation it or the user
    /// started: a link, a form, a script, back and forward. Called before
    /// each one; `nil` allows them all. `load` isn't asked about.
    ///
    /// ```swift
    /// page.navigationDecider = { $0.url.hasPrefix("https://example.com/") }
    /// ```
    public var navigationDecider: ((WebNavigation) -> Bool)?

    /// Called when the main frame finishes loading.
    public var onFinish: (() -> Void)?

    public init() { }

    deinit {
        // The host may still hold the receiver until it destroys the page.
        receiver.page = nil
        for (_, completion) in scripts {
            completion(.failure(WebError(.cancelled)))
        }
    }

    // MARK: Loading

    public func load(_ url: String) {
        content.load(url)
    }

    /// Shows `html`. Relative URLs in it resolve against `baseURL`.
    public func load(html: String, baseURL: String? = nil) {
        content.loadHTML(html, baseURL: baseURL)
    }

    /// Loads a file from the app bundle's resources, such as
    /// `"help/index.html"`. Files beside it are readable to the page.
    public func load(resource path: String) {
        content.loadResource(path)
    }

    public func reload() {
        content.reload()
    }

    public func stopLoading() {
        content.stopLoading()
    }

    public func goBack() {
        content.goBack()
    }

    public func goForward() {
        content.goForward()
    }

    // MARK: Scripts

    /// Evaluates `script` in the page. `completion` gets its value as JSON
    /// text (`nil` for `undefined` and values JSON can't hold), or the
    /// exception it threw. Pass `nil` to run a script for its effect.
    public func evaluateJavaScript(_ script: String, completion: ((Result<String?, WebError>) -> Void)?) {
        let request = nextRequest
        nextRequest = nextRequest == .max ? 1 : nextRequest + 1
        if let completion {
            scripts[request] = completion
        }
        content.evaluateJavaScript(script, request: request)
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Evaluates `script` in the page and returns its value as JSON text:
    /// `nil` for `undefined` and values JSON can't hold.
    ///
    /// ```swift
    /// let height = try await page.evaluateJavaScript("document.body.scrollHeight")
    /// ```
    ///
    /// - Throws: `WebError` with `.javaScript` when the script throws, and
    ///   `.cancelled` when the task is cancelled; the script still runs.
    public func evaluateJavaScript(_ script: String) async throws(WebError) -> String? {
        try await withCallback { (callback: Callback<String?, WebError>) in
            self.evaluateJavaScript(script) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: WebError(.cancelled))
        }
    }
    #endif

    // MARK: The host's page

    /// What a `WebView` node carries: the host page's identifier. Asking
    /// makes the page in the host.
    public var identifier: Int32 {
        if let cached = cachedIdentifier {
            return cached
        }
        let identifier = content.identifier()
        cachedIdentifier = identifier
        return identifier
    }

    private struct Values {
        var url: String?
        var title = ""
        var isLoading = false
        var estimatedProgress = 0.0
        var canGoBack = false
        var canGoForward = false
        var error: WebError?
    }

    private let registrar = ObservationRegistrar()

    private var values = Values()

    private let receiver = Receiver()

    private var made: (any WebContent)?

    private var cachedIdentifier: Int32?

    private var nextRequest: Int32 = 1

    private var scripts: [Int32: (Result<String?, WebError>) -> Void] = [:]

    private var content: any WebContent {
        if let made {
            return made
        }
        receiver.page = Unmanaged.passUnretained(self)
        let content = WebContentProxy.make(receiver)
        made = content
        return content
    }

    private func mutate(_ index: Int, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: index, change)
    }

    // MARK: From the host

    fileprivate func decide(_ navigation: WebNavigation) -> Bool {
        navigationDecider?(navigation) ?? true
    }

    fileprivate func update(url: String?) {
        guard url != values.url else { return }
        mutate(0) { values.url = url }
    }

    fileprivate func update(title: String) {
        guard title != values.title else { return }
        mutate(1) { values.title = title }
    }

    fileprivate func update(isLoading: Bool, progress: Double) {
        if isLoading, !values.isLoading, values.error != nil {
            // Another navigation started.
            mutate(6) { values.error = nil }
        }
        if isLoading != values.isLoading {
            mutate(2) { values.isLoading = isLoading }
        }
        if progress != values.estimatedProgress {
            mutate(3) { values.estimatedProgress = progress }
        }
    }

    fileprivate func update(canGoBack: Bool, canGoForward: Bool) {
        if canGoBack != values.canGoBack {
            mutate(4) { values.canGoBack = canGoBack }
        }
        if canGoForward != values.canGoForward {
            mutate(5) { values.canGoForward = canGoForward }
        }
    }

    fileprivate func finished() {
        onFinish?()
    }

    fileprivate func failed(_ error: WebError) {
        mutate(6) { values.error = error }
    }

    fileprivate func evaluated(_ request: Int32, _ result: Result<String?, WebError>) {
        guard let completion = scripts.removeValue(forKey: request) else { return }
        completion(result)
    }
}

/// The delegate the host holds. It doesn't keep the page alive: the page
/// owns the host's `WebContent`, which owns this, and the page clears the
/// reference when it's released. Embedded Swift has no weak references.
private final class Receiver: WebContentDelegate {

    var page: Unmanaged<WebPage>?

    private var current: WebPage? {
        page?.takeUnretainedValue()
    }

    func shouldNavigate(_ content: any WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        // A kind from a newer host is some other navigation.
        let navigation = WebNavigation(url: url, kind: WebNavigationKind(rawValue: kind) ?? .other, isMainFrame: isMainFrame)
        return current?.decide(navigation) ?? true
    }

    func didChangeURL(_ content: any WebContent, url: String?) {
        current?.update(url: url)
    }

    func didChangeTitle(_ content: any WebContent, title: String) {
        current?.update(title: title)
    }

    func didChangeLoading(_ content: any WebContent, isLoading: Bool, progress: Double) {
        current?.update(isLoading: isLoading, progress: progress)
    }

    func didChangeHistory(_ content: any WebContent, canGoBack: Bool, canGoForward: Bool) {
        current?.update(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func didFinishNavigation(_ content: any WebContent) {
        current?.finished()
    }

    func didFailNavigation(_ content: any WebContent, error: Int32, message: String) {
        current?.failed(WebError(WebError.Code(rawValue: error) ?? .unknown, message: message))
    }

    func didEvaluateJavaScript(_ content: any WebContent, request: Int32, result: String?, error: String?) {
        if let error {
            current?.evaluated(request, .failure(WebError(.javaScript, message: error)))
        } else {
            current?.evaluated(request, .success(result))
        }
    }
}
