import DynamicFiles
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
///
/// A page that needs more than the default, such as a private tab or a
/// mail message that loads nothing remote, is made with a configuration:
///
/// ```swift
/// guard let tab = WebPage(configuration: .init(websiteDataStore: .nonPersistent())) else {
///     return   // this host can't keep a page private
/// }
/// ```
public final class WebPage: Observable {

    /// How a page is made. It's fixed once the page is.
    public struct Configuration: Equatable, Sendable {

        /// Where the page keeps cookies, storage and caches.
        public var websiteDataStore: WebsiteDataStore

        /// `false`: no remote navigation, image, style, script or `fetch`,
        /// as for an app without `.network`. The app's own `load(html:)`
        /// and `load(resource:)` work.
        public var loadsRemoteContent: Bool

        /// `false` stops the page's own scripts. The app's
        /// `evaluateJavaScript` still runs on Apple's platforms and Linux;
        /// on Android it fails with `javaScript` while this is off.
        public var allowsJavaScript: Bool

        /// `false`: a file input shows no picker.
        public var allowsFileUploads: Bool

        public init(
            websiteDataStore: WebsiteDataStore = .default,
            loadsRemoteContent: Bool = true,
            allowsJavaScript: Bool = true,
            allowsFileUploads: Bool = true
        ) {
            self.websiteDataStore = websiteDataStore
            self.loadsRemoteContent = loadsRemoteContent
            self.allowsJavaScript = allowsJavaScript
            self.allowsFileUploads = allowsFileUploads
        }

        /// What a host must say it does to make a page like this.
        var requiredFeatures: WebFeatures {
            var features: WebFeatures = []
            if !websiteDataStore.isPersistent { features.insert(.nonPersistentStores) }
            if !loadsRemoteContent { features.insert(.remoteContentOff) }
            if !allowsJavaScript { features.insert(.pageScriptsOff) }
            return features
        }

        var options: WebPageOptions {
            var options: WebPageOptions = []
            if !loadsRemoteContent { options.insert(.noRemoteContent) }
            if !allowsJavaScript { options.insert(.noPageScripts) }
            if !allowsFileUploads { options.insert(.noUploads) }
            return options
        }
    }

    /// What this host does of `WebContent` version 2; none of it on a host
    /// built before it. A call that needs a feature the host lacks fails
    /// with `WebError.Code.unavailable`, or does nothing.
    public static var hostFeatures: WebFeatures {
        guard WebContentProxy.Methods.features.isAvailable else { return [] }
        return WebFeatures(rawValue: WebContentProxy.features())
    }

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

    public let configuration: Configuration

    /// What the page tells sites it is; `nil` is the engine's own. Needs
    /// `.userAgentAndZoom`.
    public var customUserAgent: String? {
        didSet {
            guard customUserAgent != oldValue, WebContentProxy.Methods.setCustomUserAgent.isAvailable else { return }
            content.setCustomUserAgent(customUserAgent ?? "")
        }
    }

    /// 1 is 100%. Needs `.userAgentAndZoom`.
    public var pageZoom: Double = 1 {
        didSet {
            guard pageZoom != oldValue, WebContentProxy.Methods.setPageZoom.isAvailable else { return }
            content.setPageZoom(pageZoom)
        }
    }

    /// True when the page and all it loaded came over a trusted
    /// connection. Needs `.security`.
    public var hasOnlySecureContent: Bool {
        registrar.access(self, propertyIndex: 7)
        return values.hasOnlySecureContent
    }

    /// Who the page's certificate was issued to; `nil` without one. Needs
    /// `.security`.
    public var certificateSummary: String? {
        registrar.access(self, propertyIndex: 8)
        return values.certificateSummary
    }

    /// Asked when the page opens a new window (`target="_blank"`,
    /// `window.open`), after `navigationDecider` agrees, with its URL.
    /// Return a page made with `configuration` to load the window in, such
    /// as a new tab; `nil`, or no handler, loads it in this page. Needs
    /// `.newPages`.
    ///
    /// ```swift
    /// page.newPageHandler = { url in
    ///     let tab = WebPage(configuration: page.configuration)
    ///     if let tab { tabs.append(tab) }
    ///     return tab
    /// }
    /// ```
    public var newPageHandler: ((_ url: String) -> WebPage?)?

    /// Whether to download a response the page can't show, a link with
    /// `download`, or an attachment. Without one, nothing is downloaded.
    /// Needs `.downloads`.
    public var downloadDecider: ((WebDownloadRequest) -> Bool)?

    /// Called with each download `downloadDecider` accepted, as it starts.
    public var onDownload: ((WebDownload) -> Void)?

    /// Called when a site asks for the camera, the microphone or location,
    /// and the app's manifest declares the capability for it. Answer with
    /// `grant()` or `deny()`, now or later; a request let go unanswered is
    /// denied. Without a handler every request is denied. Needs
    /// `.permissions`.
    public var onPermissionRequest: ((WebPermissionRequest) -> Void)?

    /// A page with the default configuration.
    public convenience init() {
        self.init(made: Configuration())
    }

    /// A page made as `configuration` says, or `nil` when this host can't
    /// honor it: a non-persistent store, remote content off or page
    /// scripts off that `hostFeatures` doesn't include.
    public convenience init?(configuration: Configuration) {
        guard Self.hostFeatures.isSuperset(of: configuration.requiredFeatures) else { return nil }
        self.init(made: configuration)
    }

    init(made configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        // The host may still hold the receiver until it destroys the page.
        receiver.page = nil
        let cancelled = WebError(.cancelled)
        for (_, completion) in scripts {
            completion(.failure(cancelled))
        }
        for (_, completion) in finds {
            completion(.failure(cancelled))
        }
        for (_, completion) in snapshots {
            completion(.failure(cancelled))
        }
        for (_, completion) in completions {
            completion(.failure(cancelled))
        }
        for (_, download) in downloads {
            download.cancel()
        }
    }

    // MARK: Loading

    /// Loads `url`. A remote one needs `.network` in the app's manifest;
    /// without it the load fails with `WebError.Code.notPermitted`.
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
        let request = takeRequest()
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

    // MARK: Find

    /// Highlights and scrolls to the next match of `text`, or the one
    /// before. Needs `.find`; fails with `unavailable` without it.
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false, completion: @escaping (Result<WebFindResult, WebError>) -> Void) {
        guard Self.hostFeatures.contains(.find) else {
            completion(.failure(WebError(.unavailable)))
            return
        }
        let request = takeRequest()
        finds[request] = completion
        content.find(text, backwards: backwards, caseSensitive: caseSensitive, request: request)
    }

    /// Removes find's highlight.
    public func clearFind() {
        guard let made, WebContentProxy.Methods.clearFind.isAvailable else { return }
        made.clearFind()
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Highlights and scrolls to the next match of `text`, or the one
    /// before.
    ///
    /// - Throws: `WebError` with `.unavailable` where the host has no find,
    ///   and `.cancelled` when the task is cancelled.
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) async throws(WebError) -> WebFindResult {
        try await withCallback { (callback: Callback<WebFindResult, WebError>) in
            self.find(text, backwards: backwards, caseSensitive: caseSensitive) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: WebError(.cancelled))
        }
    }
    #endif

    // MARK: Snapshots

    /// The page as it's drawn now, as PNG bytes `width` points wide, for a
    /// tab switcher's picture. Needs `.snapshots`. A page that has never
    /// been on screen may have nothing to draw, and fails with
    /// `unavailable`.
    public func snapshot(width: Double, completion: @escaping (Result<[UInt8], WebError>) -> Void) {
        guard Self.hostFeatures.contains(.snapshots) else {
            completion(.failure(WebError(.unavailable)))
            return
        }
        let request = takeRequest()
        snapshots[request] = completion
        content.snapshot(width, request: request)
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// The page as it's drawn now, as PNG bytes `width` points wide.
    ///
    /// - Throws: `WebError` with `.unavailable` where the host has no
    ///   snapshots or nothing is drawn yet, and `.cancelled` when the task
    ///   is cancelled.
    public func snapshot(width: Double) async throws(WebError) -> [UInt8] {
        try await withCallback { (callback: Callback<[UInt8], WebError>) in
            self.snapshot(width: width) { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: WebError(.cancelled))
        }
    }
    #endif

    /// What `WebsiteDataStore.removeData` asks of a page of the store.
    func removeData(since: Double, completion: @escaping (Result<Void, WebError>) -> Void) {
        let request = takeRequest()
        completions[request] = completion
        content.removeData(since: since, request: request)
    }

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
        var hasOnlySecureContent = false
        var certificateSummary: String?
    }

    private let registrar = ObservationRegistrar()

    private var values = Values()

    private let receiver = Receiver()

    private var made: (any WebContent)?

    private var cachedIdentifier: Int32?

    private var nextRequest: Int32 = 1

    private var scripts: [Int32: (Result<String?, WebError>) -> Void] = [:]

    private var finds: [Int32: (Result<WebFindResult, WebError>) -> Void] = [:]

    private var snapshots: [Int32: (Result<[UInt8], WebError>) -> Void] = [:]

    private var completions: [Int32: (Result<Void, WebError>) -> Void] = [:]

    private var downloads: [Int32: WebDownload] = [:]

    /// The `newPage` call the host page was made during, if any.
    private var madeInWindow = 0

    /// Counts `newPage` calls; the current one while one runs, else 0.
    nonisolated(unsafe) private static var window = 0

    nonisolated(unsafe) private static var windows = 0

    /// The host's page, made the first time it's needed.
    var content: any WebContent {
        if let made {
            return made
        }
        receiver.page = Unmanaged.passUnretained(self)
        let content: any WebContent
        if WebContentProxy.Methods.make_3.isAvailable {
            // Version 2: the receiver takes its events.
            content = WebContentProxy.make(receiver, dataStore: configuration.websiteDataStore.identifier, options: configuration.options.rawValue)
        } else {
            content = WebContentProxy.make(receiver)
        }
        made = content
        madeInWindow = Self.window
        return content
    }

    private func takeRequest() -> Int32 {
        let request = nextRequest
        nextRequest = nextRequest == .max ? 1 : nextRequest + 1
        return request
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

    /// The host page to load a new window in, made during this call, or
    /// `nil` for this page.
    fileprivate func openWindow(_ url: String) -> (any WebContent)? {
        guard let newPageHandler else { return nil }
        Self.windows += 1
        let call = Self.windows
        let outer = Self.window
        Self.window = call
        defer { Self.window = outer }
        guard let page = newPageHandler(url), page !== self else { return nil }
        if page.made == nil {
            return page.content
        }
        // A page made before this call has a view of its own already.
        return page.madeInWindow == call ? page.content : nil
    }

    fileprivate func shouldDownload(_ identifier: Int32, _ request: WebDownloadRequest) -> Bool {
        guard let downloadDecider, downloadDecider(request), let content = made else { return false }
        let download = WebDownload(identifier, request, content: content)
        downloads[identifier] = download
        onDownload?(download)
        return true
    }

    fileprivate func download(_ identifier: Int32) -> WebDownload? {
        downloads[identifier]
    }

    fileprivate func endDownload(_ identifier: Int32) -> WebDownload? {
        downloads.removeValue(forKey: identifier)
    }

    fileprivate func found(_ request: Int32, _ result: WebFindResult) {
        finds.removeValue(forKey: request)?(.success(result))
    }

    fileprivate func update(hasOnlySecureContent: Bool, certificateSummary: String?) {
        if hasOnlySecureContent != values.hasOnlySecureContent {
            mutate(7) { values.hasOnlySecureContent = hasOnlySecureContent }
        }
        if certificateSummary != values.certificateSummary {
            mutate(8) { values.certificateSummary = certificateSummary }
        }
    }

    fileprivate func permission(_ request: Int32, origin: String, kinds: WebPermissionKinds) {
        guard let content = made else { return }
        let asked = WebPermissionRequest(request, origin: origin, kinds: kinds, content: content)
        if let onPermissionRequest {
            onPermissionRequest(asked)
        } else {
            asked.deny()
        }
    }

    fileprivate func snapshotted(_ request: Int32, _ png: [UInt8]) {
        snapshots.removeValue(forKey: request)?(.success(png))
    }

    fileprivate func completed(_ request: Int32) {
        completions.removeValue(forKey: request)?(.success(()))
    }

    fileprivate func failed(_ request: Int32, _ error: WebError) {
        if let completion = finds.removeValue(forKey: request) {
            completion(.failure(error))
        } else if let completion = snapshots.removeValue(forKey: request) {
            completion(.failure(error))
        } else if let completion = completions.removeValue(forKey: request) {
            completion(.failure(error))
        }
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

    // MARK: Since version 2

    func newPage(_ content: any WebContent, url: String) -> (any WebContent)? {
        current?.openWindow(url)
    }

    func shouldDownload(_ content: any WebContent, download: Int32, url: String, suggestedName: String, mimeType: String, expectedLength: Int64) -> Bool {
        let request = WebDownloadRequest(url: url, suggestedName: suggestedName, mimeType: mimeType, expectedLength: expectedLength < 0 ? nil : expectedLength)
        return current?.shouldDownload(download, request) ?? false
    }

    func didChangeDownload(_ content: any WebContent, download: Int32, received: Int64, expected: Int64) {
        current?.download(download)?.progressed(received: received, expected: expected)
    }

    func didFinishDownload(_ content: any WebContent, download: Int32, path: String) {
        current?.endDownload(download)?.finished(FilePath(.caches, path))
    }

    func didFailDownload(_ content: any WebContent, download: Int32, error: Int32, message: String) {
        current?.endDownload(download)?.failed(WebError(WebError.Code(rawValue: error) ?? .unknown, message: message))
    }

    func didFind(_ content: any WebContent, request: Int32, matchFound: Bool, count: Int32, index: Int32) {
        let result = WebFindResult(
            matchFound: matchFound,
            matchCount: count < 0 ? nil : Int(count),
            matchIndex: index < 0 ? nil : Int(index)
        )
        current?.found(request, result)
    }

    func didChangeSecurity(_ content: any WebContent, hasOnlySecureContent: Bool, certificateSummary: String) {
        current?.update(hasOnlySecureContent: hasOnlySecureContent, certificateSummary: certificateSummary.isEmpty ? nil : certificateSummary)
    }

    func didRequestPermission(_ content: any WebContent, request: Int32, origin: String, kinds: Int32) {
        guard let page = current else {
            content.answerPermission(request, granted: false)
            return
        }
        page.permission(request, origin: origin, kinds: WebPermissionKinds(rawValue: kinds))
    }

    func didSnapshot(_ content: any WebContent, request: Int32, png: [UInt8]) {
        current?.snapshotted(request, png)
    }

    func didCompleteRequest(_ content: any WebContent, request: Int32) {
        current?.completed(request)
    }

    func didFailRequest(_ content: any WebContent, request: Int32, error: Int32, message: String) {
        current?.failed(request, WebError(WebError.Code(rawValue: error) ?? .unknown, message: message))
    }
}
