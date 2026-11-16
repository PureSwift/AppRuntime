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
public struct WebView: View {

    let page: WebPage?

    let url: String?

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
        _RenderNodeView("WebView", props: ["page": .int(Int(shown.identifier))])
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
