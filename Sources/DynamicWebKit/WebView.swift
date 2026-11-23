import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Shows web content. It takes the space it's offered.
///
/// For a page the app follows or controls, make a `WebPage` and show it:
///
/// ```swift
/// WebView(page)
/// ```
///
/// To only show a URL, give that; the view keeps a page of its own, and
/// loads again when the URL it's given changes:
///
/// ```swift
/// WebView(url: "https://swift.org")
/// ```
///
/// A `WebView` node has `page`, the identifier of the host's page
/// (`WebContent.identifier()`). The host draws that page there; everything
/// else about it goes through the `WebContent` contract.
///
/// The platform's find bar, swipes between history entries and pinch to
/// zoom are off unless asked for:
///
/// ```swift
/// WebView(page)
///     .findNavigator(isPresented: $finding)
///     .webViewBackForwardNavigationGestures(.enabled)
///     .webViewMagnificationGestures(.enabled)
/// ```
public struct WebView: View {

    /// Whether the platform's gestures for a page are on.
    public enum GestureBehavior: Equatable, Sendable {
        /// The host's choice: off, as in version 1.
        case automatic
        case enabled
        case disabled
    }

    public typealias BackForwardNavigationGesturesBehavior = GestureBehavior

    public typealias MagnificationGesturesBehavior = GestureBehavior

    let page: WebPage?

    let url: String?

    var findBar: Binding<Bool>?

    var backForwardGestures = GestureBehavior.automatic

    var magnificationGestures = GestureBehavior.automatic

    /// The page of a view made from a URL, kept across updates.
    @State private var owned = OwnedPage()

    public init(_ page: WebPage) {
        self.page = page
        self.url = nil
    }

    public init(url: String?) {
        self.page = nil
        self.url = url
    }

    public var body: some View {
        var props: [String: PropValue] = ["page": .int(Int(shown.identifier))]
        var events: [RenderEventKind: (PropValue?) -> Void] = [:]
        if let findBar {
            props["findNavigator"] = .bool(findBar.wrappedValue)
            events[.change] = { value in
                // The user closed the bar.
                if value == .bool(false), findBar.wrappedValue {
                    findBar.wrappedValue = false
                }
            }
        }
        if backForwardGestures != .automatic {
            props["backForwardGestures"] = .bool(backForwardGestures == .enabled)
        }
        if magnificationGestures != .automatic {
            props["magnificationGestures"] = .bool(magnificationGestures == .enabled)
        }
        return _RenderContainerView("WebView", props: props, selection: nil as Binding<Int?>?, events: events) {
            EmptyView()
        }
    }

    /// Shows the platform's find bar over the page while `isPresented` is
    /// true; closing it sets `isPresented` false. Where the host has none
    /// (`WebFeatures.findNavigator`), nothing shows.
    public func findNavigator(isPresented: Binding<Bool>) -> WebView {
        var view = self
        view.findBar = isPresented
        return view
    }

    /// The platform's swipe between history entries.
    public func webViewBackForwardNavigationGestures(_ behavior: BackForwardNavigationGesturesBehavior) -> WebView {
        var view = self
        view.backForwardGestures = behavior
        return view
    }

    /// Pinch to zoom, where the engine has it.
    public func webViewMagnificationGestures(_ behavior: MagnificationGesturesBehavior) -> WebView {
        var view = self
        view.magnificationGestures = behavior
        return view
    }

    private var shown: WebPage {
        if let page {
            return page
        }
        owned.show(url)
        return owned.page
    }
}

/// A `WebView(url:)`'s own page, and the URL it last asked it for.
final class OwnedPage {

    let page = WebPage()

    private var requested: String?

    func show(_ url: String?) {
        guard url != requested else { return }
        requested = url
        if let url {
            page.load(url)
        }
    }
}
