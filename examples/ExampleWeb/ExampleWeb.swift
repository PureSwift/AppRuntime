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
///
/// With `WebContent` version 2 it has tabs, which a link that opens a new
/// window opens too; a private tab; find, and the platform's find bar; a
/// list of downloads; a site's request for the camera, which it asks the
/// user about; a picture of the tab; and a message page that loads nothing
/// remote and runs no scripts, as a mail reader's would.
@Observable
final class Browser {

    var address: String = "https://swift.org/"

    /// What the last script, search or refused navigation had to say.
    var status: String = ""

    var tabs: [WebPage] = []

    var current: Int = 0

    var findText: String = ""

    var finding: Bool = false

    var downloads: [WebDownload] = []

    /// A site's request, while the user hasn't answered it.
    var permission: WebPermissionRequest? = nil

    /// Shared by every private tab, and gone with the last of them.
    @ObservationIgnored let privateStore = WebsiteDataStore.nonPersistent()

    var page: WebPage {
        tabs[current]
    }

    /// The closures hold the browser, which lives as long as the app does:
    /// Embedded Swift has no weak or unowned references.
    func start() {
        let page = WebPage()
        prepare(page)
        tabs = [page]
        page.load(address)
    }

    /// What every tab does: the same decider, downloads and permissions.
    func prepare(_ page: WebPage) {
        page.navigationDecider = { navigation in
            let url = navigation.url
            if url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("about:") {
                return true
            }
            self.status = "Blocked \(url)"
            return false
        }
        // The closures name the tab by its identifier and configuration: one
        // that held the tab would keep it alive.
        let identifier = page.identifier
        page.onFinish = {
            // Show where the page ended up, after redirects and links.
            if self.page.identifier == identifier, let url = self.page.url {
                self.address = url
            }
        }
        // A link that opens a new window opens a tab, like this one.
        let configuration = page.configuration
        page.newPageHandler = { _ in
            guard let tab = WebPage(configuration: configuration) else { return nil }
            self.add(tab)
            return tab
        }
        page.downloadDecider = { request in
            request.mimeType != "application/x-msdownload"
        }
        page.onDownload = { download in
            self.downloads.append(download)
        }
        page.onPermissionRequest = { request in
            self.permission?.deny()
            self.permission = request
        }
    }

    func add(_ tab: WebPage) {
        prepare(tab)
        tabs.append(tab)
        current = tabs.count - 1
    }

    func select(_ index: Int) {
        current = index
        address = page.url ?? ""
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

    func openPrivateTab() {
        guard let tab = WebPage(configuration: WebPage.Configuration(websiteDataStore: privateStore)) else {
            status = "This host can't keep a tab private"
            return
        }
        add(tab)
        address = ""
    }

    /// A message, as a mail reader shows one: its images and scripts stay
    /// off, though the app can reach the network.
    func showMessage() {
        let configuration = WebPage.Configuration(loadsRemoteContent: false, allowsJavaScript: false)
        guard let message = WebPage(configuration: configuration) else {
            status = "This host can't show a message safely"
            return
        }
        add(message)
        address = ""
        message.load(html: "<h1>Hello</h1><img src=\"https://tracker.example/pixel.gif\">")
    }

    func find() {
        page.find(findText) { result in
            switch result {
            case .success(let found):
                if !found.matchFound {
                    self.status = "Not found"
                } else if let count = found.matchCount {
                    self.status = "Found \(count) matches"
                } else {
                    self.status = "Found"
                }
            case .failure(let error):
                self.status = error.code == .unavailable ? "No find on this host" : "Find failed"
            }
        }
    }

    func takePicture() {
        page.snapshot(width: 320) { result in
            switch result {
            case .success(let png):
                self.status = "Picture: \(png.count) bytes"
            case .failure:
                self.status = "No picture"
            }
        }
    }

    func answer(_ granted: Bool) {
        permission?.answer(granted)
        permission = nil
    }
}

func describe(_ download: WebDownload) -> String {
    let name = download.request.suggestedName
    if download.file != nil {
        return "\(name): done"
    }
    if let error = download.error {
        return error.code == .cancelled ? "\(name): cancelled" : "\(name): failed"
    }
    if let expected = download.expectedLength {
        return "\(name): \(download.bytesReceived) of \(expected) bytes"
    }
    return "\(name): \(download.bytesReceived) bytes"
}

func describe(_ kinds: WebPermissionKinds) -> String {
    var names: [String] = []
    if kinds.contains(.camera) { names.append("the camera") }
    if kinds.contains(.microphone) { names.append("the microphone") }
    if kinds.contains(.location) { names.append("your location") }
    return names.isEmpty ? "something" : names.joined(separator: " and ")
}

struct ContentView: View {

    @Bindable var browser: Browser

    var body: some View {
        let page = browser.page
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(browser.tabs.indices, id: { $0 }) { index in
                    let tab = browser.tabs[index]
                    Button(tab.title.isEmpty ? "New Tab" : tab.title) { browser.select(index) }
                        .disabled(index == browser.current)
                }
                Button("Private Tab") { browser.openPrivateTab() }
                Button("Message") { browser.showMessage() }
            }
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
                Button("Picture") { browser.takePicture() }
            }
            TextField("Address", text: $browser.address)
                .onSubmit { browser.go() }
            HStack(spacing: 8) {
                TextField("Find", text: $browser.findText)
                    .onSubmit { browser.find() }
                    .accessibilityIdentifier("find")
                Button("Find") { browser.find() }
                Button("Find Bar") { browser.finding = true }
            }
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
            }
            if let error = page.error {
                Text("Couldn't load the page: \(error.message)")
                    .accessibilityIdentifier("error")
            }
            if let request = browser.permission {
                HStack(spacing: 8) {
                    Text("\(request.origin) wants to use \(describe(request.kinds))")
                        .accessibilityIdentifier("permission")
                    Button("Allow") { browser.answer(true) }
                    Button("Don't Allow") { browser.answer(false) }
                }
            }
            WebView(page)
                .findNavigator(isPresented: $browser.finding)
                .webViewBackForwardNavigationGestures(.enabled)
            HStack(spacing: 8) {
                if page.hasOnlySecureContent {
                    Text("Secure")
                        .accessibilityIdentifier("secure")
                }
                Text(page.title)
                    .accessibilityIdentifier("title")
            }
            Text(browser.status)
                .accessibilityIdentifier("status")
            ForEach(browser.downloads.indices, id: { $0 }) { index in
                let download = browser.downloads[index]
                HStack(spacing: 8) {
                    Text(describe(download))
                        .accessibilityIdentifier("download")
                    if !download.isFinished {
                        Button("Cancel") { download.cancel() }
                    }
                }
            }
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
