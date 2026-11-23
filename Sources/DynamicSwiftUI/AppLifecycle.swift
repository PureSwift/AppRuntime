import DynamicRuntime
import DynamicUI

// MARK: - Scene phase

/// Whether the app is in the foreground, from the host's `Application`
/// state. The frontend has one window, so it's the app's phase.
public enum ScenePhase: Sendable, Comparable {
    /// Not visible. The host may suspend the app soon.
    case background
    /// In the foreground but not receiving events.
    case inactive
    /// In the foreground and receiving events.
    case active

    init(_ state: ApplicationState) {
        switch state {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        }
    }
}

extension EnvironmentValues.Key where Value == ScenePhase {

    /// `@Environment(.scenePhase)`: the view updates when it changes.
    public static var scenePhase: Self {
        Self(read: { $0.scenePhase }, write: { $0.scenePhase = $1 })
    }
}

// MARK: - Opening URLs

/// Opens a URL in the app that handles it: `@Environment(.openURL)`.
///
/// ```swift
/// @Environment(.openURL) var openURL
/// // …
/// Button("Call") { openURL("tel:5551234") }
/// ```
///
/// An app's own, set with `environment(.openURL, _:)`, sees each URL first,
/// from code and from a `Link` below it, and says what becomes of it.
public struct OpenURLAction {

    /// What an app's action did with a URL.
    public struct Result {

        enum Kind {
            case handled
            case discarded
            case system(String?)
        }

        let kind: Kind

        /// The app did it: `accepted` is `true`.
        public static var handled: Result { Result(kind: .handled) }

        /// Nothing opens: `accepted` is `false`.
        public static var discarded: Result { Result(kind: .discarded) }

        /// The action above this one opens it, or the host.
        public static var systemAction: Result { Result(kind: .system(nil)) }

        /// The action above this one opens `url` instead, or the host.
        public static func systemAction(_ url: String) -> Result {
            Result(kind: .system(url))
        }
    }

    let handler: ((String) -> Result)?

    /// The action above this one in the tree, once it's placed there.
    var fallback: ((String) -> Bool)?

    public init(handler: @escaping (_ url: String) -> Result) {
        self.handler = handler
    }

    init() {
        self.handler = nil
    }

    /// The host's: no action of the app's.
    static var system: OpenURLAction { OpenURLAction() }

    /// Whether the app set one, so a `Link` asks it.
    var isCustom: Bool {
        handler != nil
    }

    public func callAsFunction(_ url: String) {
        _ = open(url)
    }

    /// `accepted`: whether the URL was opened, by the app or the host. On
    /// iOS the host's `true` means the system was asked.
    public func callAsFunction(_ url: String, completion: (_ accepted: Bool) -> Void) {
        completion(open(url))
    }

    func open(_ url: String) -> Bool {
        guard let handler else {
            return AppLifecycle.shared.openInHost(url)
        }
        switch handler(url).kind {
        case .handled:
            return true
        case .discarded:
            return false
        case .system(let other):
            let target = other ?? url
            return fallback?(target) ?? AppLifecycle.shared.openInHost(target)
        }
    }
}

extension EnvironmentValues.Key where Value == OpenURLAction {

    /// `@Environment(.openURL)`. Set an app's own with
    /// `environment(.openURL, OpenURLAction { url in … })`; its
    /// `.systemAction` goes to the one above it.
    public static var openURL: Self {
        Self(read: { $0.openURL }, write: { values, action in
            var placed = action
            let above = values.openURL
            placed.fallback = { above.open($0) }
            values.openURL = placed
        })
    }
}

// MARK: - The app's Application

/// The frontend's own `Application`, made when the app starts: its phase,
/// the URLs it's opened with, and whether the screen stays awake.
final class AppLifecycle: ApplicationDelegate {

    nonisolated(unsafe) static let shared = AppLifecycle()

    private(set) var application: (any Application)?

    private(set) var phase = ScenePhase.active

    /// `onOpenURL` handlers on screen, in the order they appeared.
    private var urlHandlers: [URLHandler] = []

    /// URLs that arrived while no handler was on screen.
    private(set) var pendingURLs: [String] = []

    /// `idleTimerDisabled` modifiers on screen.
    private var idleRequests: [IdleRequest] = []

    /// What the host was last told.
    private(set) var isIdleTimerDisabled = false

    /// Makes the application, where the host has the contract. Once.
    func start() {
        guard application == nil, ApplicationProxy.isAvailable else { return }
        application = try? ApplicationProxy.make(self)
        if let state = try? application?.state(), let known = ApplicationState(rawValue: state) {
            phase = ScenePhase(known)
        }
    }

    /// Forgets everything, for tests.
    func reset() {
        application = nil
        phase = .active
        urlHandlers = []
        pendingURLs = []
        idleRequests = []
        isIdleTimerDisabled = false
    }

    func openInHost(_ url: String) -> Bool {
        guard let application else { return false }
        return (try? application.openURL(url)) ?? false
    }

    // MARK: onOpenURL

    func add(_ handler: URLHandler) {
        urlHandlers.append(handler)
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        for url in urls {
            handler.action(url)
        }
    }

    func remove(_ handler: URLHandler) {
        urlHandlers.removeAll { $0 === handler }
    }

    // MARK: idleTimerDisabled

    func add(_ request: IdleRequest) {
        idleRequests.append(request)
        updateIdleTimer()
    }

    func remove(_ request: IdleRequest) {
        idleRequests.removeAll { $0 === request }
        updateIdleTimer()
    }

    func updateIdleTimer() {
        let disabled = idleRequests.contains { $0.disabled }
        guard disabled != isIdleTimerDisabled else { return }
        isIdleTimerDisabled = disabled
        try? application?.setIdleTimerDisabled(disabled)
    }

    // MARK: ApplicationDelegate

    func didChangeState(_ application: any Application, state: Int32) {
        guard let known = ApplicationState(rawValue: state) else { return }
        let phase = ScenePhase(known)
        guard phase != self.phase else { return }
        self.phase = phase
        for graph in HostRenderer.running {
            graph.setNeedsUpdate()
        }
    }

    func didReceiveMemoryWarning(_ application: any Application) { }

    /// Every handler on screen gets it; with none, the first to appear
    /// does.
    func open(_ application: any Application, url: String) -> Bool {
        guard !urlHandlers.isEmpty else {
            pendingURLs.append(url)
            return true
        }
        for handler in urlHandlers {
            handler.action(url)
        }
        return true
    }
}

/// One `onOpenURL`, with the closure of the view's last update.
final class URLHandler {
    var action: (String) -> Void = { _ in }
}

/// One `idleTimerDisabled`, with the value of the view's last update.
final class IdleRequest {
    var disabled = false
}

extension View {

    /// Gets each URL the app is opened with, a deep link or a custom
    /// scheme, while the view is on screen. Every view on screen with one
    /// gets it. A URL that arrives while none is, such as the one that
    /// launched the app, goes to the first that appears.
    public func onOpenURL(perform action: @escaping (_ url: String) -> Void) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: nil) { id, graph in
            let handler = graph.stateBox { URLHandler() }.value
            handler.action = action
            graph.register(ViewGraph.Appearance(
                node: id,
                onAppear: { AppLifecycle.shared.add(handler) },
                onDisappear: { AppLifecycle.shared.remove(handler) }
            ))
        }
    }

    /// Keeps the screen from dimming or locking while the view is on screen
    /// and `disabled` is true. The host lets it sleep again while the app
    /// is in the background. The name is UIKit's; SwiftUI has no modifier
    /// for it.
    ///
    /// ```swift
    /// VideoPlayer(player: player)
    ///     .idleTimerDisabled(player.isPlaying)
    /// ```
    public func idleTimerDisabled(_ disabled: Bool = true) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: nil) { id, graph in
            let request = graph.stateBox { IdleRequest() }.value
            if request.disabled != disabled {
                request.disabled = disabled
                AppLifecycle.shared.updateIdleTimer()
            }
            graph.register(ViewGraph.Appearance(
                node: id,
                onAppear: { AppLifecycle.shared.add(request) },
                onDisappear: { AppLifecycle.shared.remove(request) }
            ))
        }
    }
}
