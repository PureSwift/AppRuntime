import DynamicRuntime
// Guest builds call the frontend `SwiftUI` and the web module `WebKit`; host
// builds of this package can't, since Apple's SDK has both. A guest package
// just says `import SwiftUI` and `import WebKit`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if canImport(DynamicWebKit)
import DynamicWebKit
#else
import WebKit
#endif

/// The example web app: a small browser. An address field, back, forward,
/// reload and stop around a `WebView`; the page's title and progress; a
/// script that counts the page's links; and a decider that keeps the page
/// on the web, refusing schemes such as `tel:` and `mailto:`.
@Observable
final class Browser {

    var address: String = "https://swift.org/"

    /// What the last script or refused navigation had to say.
    var status: String = ""

    @ObservationIgnored let page = WebPage()

    /// The closures hold the browser, which lives as long as the app does:
    /// Embedded Swift has no weak or unowned references.
    func start() {
        page.navigationDecider = { navigation in
            let url = navigation.url
            if url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("about:") {
                return true
            }
            self.status = "Blocked \(url)"
            return false
        }
        page.onFinish = {
            // Show where the page ended up, after redirects and links.
            if let url = self.page.url {
                self.address = url
            }
        }
        page.load(address)
    }

    func go() {
        status = ""
        page.load(address)
    }

    func countLinks() {
        page.evaluateJavaScript("document.links.length") { result in
            switch result {
            case .success(let count):
                self.status = "Links: \(count ?? "none")"
            case .failure(let error):
                self.status = "Script failed: \(error.message)"
            }
        }
    }
}

struct ContentView: View {

    @Bindable var browser: Browser

    var body: some View {
        let page = browser.page
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Back") { page.goBack() }
                    .disabled(!page.canGoBack)
                Button("Forward") { page.goForward() }
                    .disabled(!page.canGoForward)
                Button(page.isLoading ? "Stop" : "Reload") {
                    if page.isLoading {
                        page.stopLoading()
                    } else {
                        page.reload()
                    }
                }
                Button("Count links") { browser.countLinks() }
            }
            TextField("Address", text: $browser.address)
                .onSubmit { browser.go() }
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
            }
            if let error = page.error {
                Text("Couldn't load the page: \(error.message)")
                    .accessibilityIdentifier("error")
            }
            WebView(page)
            Text(page.title)
                .accessibilityIdentifier("title")
            Text(browser.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleWebApp: App {

    let browser = Browser()

    init() {
        browser.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleWebMain() -> rt_status {
    Runtime.main { ExampleWebApp.run() }
}
