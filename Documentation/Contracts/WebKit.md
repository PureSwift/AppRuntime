# Web views

Module `DynamicWebKit`, which guest code imports as `WebKit`: a page of web
content, and the view that shows it.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `WebContent` | contract (no capability) | `WKWebView` | `android.webkit.WebView` | WPE WebKit's `WebKitWebView` | an `<iframe>` |
| `WebContentDelegate` | callback | `WKNavigationDelegate`, key-value observing | `WebViewClient`, `WebChromeClient` | the view's signals and properties | `load` events |

The Darwin host implements them on iOS and macOS over `WKWebView`
(DarwinAppRuntime's `DarwinWebKit`). Android, Linux and the browser have no
host yet. The guest side and an example (`examples/ExampleWeb`, a small
browser) exist, tested against a stand-in for the engine. Version 2 (below)
is built on the guest side; no host implements it yet.

Guest-side Swift: `WebPage`, the observable page app code uses; `WebView`,
the SwiftUI view; `WebNavigation`, `WebNavigationKind` and `WebError`.

The render IR gains one node, `WebView`, whose `page` prop is the host
page's `identifier()`. In version 1 it has no events: everything about a
page goes through the contract. Version 2 adds the find bar's `change`.

## For a guest

```swift
import SwiftUI
import WebKit

struct HelpView: View {

    let page: WebPage

    var body: some View {
        VStack {
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
            }
            WebView(page)
            Text(page.title)
        }
    }
}

let page = WebPage()
page.load("https://example.com/help")
```

To only show a URL, `WebView(url: "https://swift.org")` keeps a page of its
own, and loads again when the URL it's given changes.

- **A page is separate from where it's shown.** It loads as soon as it's
  told to, on screen or not, and keeps its history and scroll position
  while its view comes and goes. Releasing the `WebPage` destroys it.
- **`WebPage` is observable:** `url`, `title`, `isLoading`,
  `estimatedProgress`, `canGoBack`, `canGoForward` and `error` update the
  views that read them.
- **`url` is where the page is, not what you asked for.** It changes when a
  navigation commits, and follows redirects and links. `onFinish` is called
  when a load completes.
- **Loading:** `load(_:)`, `load(html:baseURL:)`, `load(resource:)` for a
  file in the app bundle, `reload()`, `stopLoading()`, `goBack()`,
  `goForward()`.
- **Deciding navigations:** `navigationDecider` is asked, and waited for,
  before each navigation the page or the user starts. Return `false` to
  refuse it, for example to keep a page on one site or to hand `tel:` links
  to the system.
- **Scripts:** `evaluateJavaScript(_:)` runs a script in the page and
  returns its value as JSON text, or throws what the script threw. There's
  a completion-handler form for code that isn't async.
- **Layout:** a `WebView` takes the space it's offered and scrolls its own
  content. Inside a `ScrollView`, give it a height.
- **`.network` in the manifest is for remote content.** Without it a page
  can show an HTML string or a file from the bundle, and nothing remote: a
  remote URL fails with `WebError.Code.notPermitted`, and remote images,
  scripts and links in local pages don't load.

### What isn't there yet

- Messages from a page's scripts to the app. A page can only be asked,
  with `evaluateJavaScript`.
- Cookies and site data, a custom user agent, find in page, zoom, and
  back-and-forward swipes.
- Downloads and file uploads.
- Camera, microphone and location for pages: requests are refused.

All but the first are drafted below, for review:
[Version 2: a browser and a mail reader](#version-2-a-browser-and-a-mail-reader).

## Version 2: a browser and a mail reader

**Status:** reviewed and built on the guest side: the contract, `WebPage`,
`WebView`'s modifiers, tests against a stand-in engine, and
`ExampleWeb` on the three engines. No host implements version 2 yet;
"What hosts still need" is the list.

A browser needs more of a page than version 1 gives: tabs a link opens,
private windows, downloads, find, zoom, the lock icon, a page's request
for the camera, and a picture of each tab. A mail reader needs one thing
the other way: a page that loads nothing remote and runs no scripts,
though the app has `.network`. This is all one contract's second
version.

### What shapes it

- **Methods, not contracts.** An app declares every contract and callback
  of the modules it links, and a host refuses one that declares an
  interface it lacks. A new contract in `DynamicWebKit` would make every
  app with a web view fail on every host until each had it. A method a
  host lacks is only absent (`Methods.x.isAvailable`), and a contract at
  a lower version is a warning. So `WebContent` and `WebContentDelegate`
  become version 2, and nothing is added beside them.
- **A host must know which delegates have the new methods.** It calls the
  delegate, and a method a version 1 guest's delegate lacks would trap.
  So version 2 pages are made by a new constructor, `make(_:dataStore:
  options:)`, and only a page made by it is told version 2 events. A
  version 1 guest never calls it.
- **A default isn't the same as support.** Host repos conform to
  `WebContent` themselves, so every new method gets a default that does
  nothing, and a host built against this compiles unchanged. A guest can't
  then tell an honored method from a default by `isAvailable`. So a host
  says what it honors in `features()`, which is 0 by default, and the
  guest offers only that. What would be a privacy failure if ignored,
  such as a private page that kept its cookies or a mail page that loaded
  remote images, is refused instead: the page isn't made.
- **The engine's own UI where the platform has one.** Script dialogs,
  sign-in to a site, the file picker for an upload and the find bar are
  the platform's, shown by the host. The app is asked only what it
  decides: whether a link opens a tab, whether to download, whether a
  site may use the camera.

### For a guest

```swift
import SwiftUI
import WebKit

// A private tab: its cookies and storage go when its last page does.
let store = WebsiteDataStore.nonPersistent()
guard let tab = WebPage(configuration: WebPage.Configuration(websiteDataStore: store)) else {
    return   // this host can't keep a page private: offer no private tabs
}

// A message, shown without reaching the network or running its scripts.
let message = WebPage(configuration: WebPage.Configuration(loadsRemoteContent: false, allowsJavaScript: false))
message?.load(html: body, baseURL: nil)

page.customUserAgent = "ExampleBrowser/1.0"
page.pageZoom = 1.25

// A link that opens a new window opens a tab instead.
let configuration = page.configuration
page.newPageHandler = { url in
    guard let tab = WebPage(configuration: configuration) else { return nil }
    tabs.append(tab)
    return tab
}

// Downloads go to the app's caches; the app moves them where the user says.
page.downloadDecider = { request in request.mimeType != "application/x-msdownload" }
page.onDownload = { download in downloads.append(download) }

// A site asks for the camera: the app asks the user its own way, and
// answers when they do.
page.onPermissionRequest = { request in
    pending = request   // a prompt that calls request.grant() or request.deny()
}

let result = try await page.find("swift", backwards: false)   // matchFound, and a count where the engine says
let png = try await page.snapshot(width: 320)                  // a tab switcher's picture

try await WebsiteDataStore.default.removeData()   // "Clear history and data": since 0, everything

if WebPage.hostFeatures.contains(.find) { /* offer Find */ }

WebView(page)
    .findNavigator(isPresented: $finding)
    .webViewBackForwardNavigationGestures(.enabled)
    .webViewMagnificationGestures(.enabled)
```

- **`WebPage(configuration:)` is nil** when the host doesn't honor what
  the configuration asks: a non-persistent store, remote content off, or
  scripts off on a host that doesn't say so in `features()`. `WebPage()`
  is the default configuration and is never nil.
- **`WebPage.Configuration`** is fixed when the page is made:
  `websiteDataStore` (`.default`, or a `.nonPersistent()` store pages can
  share), `loadsRemoteContent`, `allowsJavaScript` and
  `allowsFileUploads`. Apple's `WebPage.Configuration` has the first
  name; the rest are this module's.
- **`loadsRemoteContent: false` is a page without `.network`:** no remote
  navigation, image, style, script or `fetch`, and a remote navigation
  fails with `notPermitted`. The app's own `load(html:)` and `load(resource:)`
  work.
- **`allowsJavaScript: false`** stops the page's own scripts.
  `evaluateJavaScript` still runs the app's on Apple's platforms and in
  WPE. On Android the setting is the engine's only one, and the app's
  scripts fail with `javaScript` while it's off.
- **Settable at any time:** `customUserAgent` (`nil`: the engine's),
  and `pageZoom` (1 is 100%).
- **`newPageHandler`** is asked when the page opens a new window
  (`target="_blank"`, `window.open`), after `navigationDecider` agrees.
  It returns a page to load there, made with `page.configuration`,
  whatever it asks: the engine makes the new window's view with the
  opener's settings. `nil`, or no handler, loads it in the same page, as
  version 1 does. The new page keeps `window.opener` where the engine
  allows it.
- **Downloads.** A response the engine can't show, a link with
  `download`, or `Content-Disposition: attachment` is a download.
  `downloadDecider` is asked with the URL, suggested name, MIME type and
  expected length; without one, downloads are refused as in version 1.
  An accepted `WebDownload` is observable: `bytesReceived`,
  `expectedLength`, `file`, a `FilePath` in `.caches` under `Downloads/`
  once it's done, and `error`. `cancel()` stops it. The file is the
  app's; the user's copy is the app's to make with `DocumentPicker`'s
  `export`.
- **Uploads** show the platform's file picker, and what the user picks
  goes to the page. The app isn't asked and doesn't see the file. Off
  with `allowsFileUploads: false`.
- **Find.** `find(_:backwards:caseSensitive:)` highlights and scrolls to
  the next match and says whether there was one, with a count and the
  match's place where the engine gives them (Android does; Apple's
  engines don't). `clearFind()` removes the highlight.
  `findNavigator(isPresented:)` shows the platform's own find bar, which
  sets the binding false when the user closes it.
- **Security.** `hasOnlySecureContent` is true when the page and all it
  loaded came over a trusted connection; `certificateSummary` names who
  the certificate was issued to. A certificate that isn't trusted fails
  the navigation with `security`, as in version 1: there's no "visit
  anyway".
- **Script dialogs and sign-in** (`alert`, `confirm`, `prompt`, and an
  HTTP sign-in challenge) are the platform's dialogs, over the page. A
  client certificate is refused.
- **Permissions.** A site's request for the camera, the microphone or
  location goes to `onPermissionRequest` as a `WebPermissionRequest`,
  with the site's origin and what it asks for, and the host waits until
  the app calls `grant()` or `deny()`; one let go unanswered is denied. The app's manifest must declare
  the capability for it, or the request is refused without asking; the
  platform then asks the user for the app as it does for any of the app's
  own uses. Without a decider, requests are refused, as in version 1.
  The app remembers per site if it wants to; the engine doesn't.
- **`snapshot(width:)`** is the page as it's drawn now, as PNG bytes
  `width` points wide, for `Image(data:)` where the app links
  `DynamicDrawing`. A page that has never been on screen may have nothing
  to draw on some engines, and fails with `unavailable`.
- **`WebsiteDataStore.removeData(since:)`** removes cookies, storage,
  caches and the rest of what sites kept since a time, in seconds since
  1970 (0, the default, is everything), for every page that uses the
  store.
- **Gestures.** `webViewBackForwardNavigationGestures` turns on the
  platform's swipe between history entries, and
  `webViewMagnificationGestures` pinch to zoom where the engine has it.
  Both are off by default, as in version 1. The names are Apple's.

### The contract, version 2

Added to `WebContent`, each with a default in a protocol extension that
does nothing:

```swift
@DynamicRuntime("org.pureswift.web.WebContent", version: 2)
public protocol WebContent: AnyObject {

    // … version 1 …

    /// A `WebFeatures` bit set of what this host honors. Default 0.
    static func features() -> Int32

    /// A page whose delegate takes version 2's events. `dataStore` 0 is
    /// the app's default store; another number names a non-persistent
    /// store, kept while a page uses it. `options` is `WebPageOptions`
    /// bits: 1 no remote content, 2 no page scripts, 4 no uploads.
    /// Default: `make(delegate)`.
    static func make(_ delegate: WebContentDelegate, dataStore: Int32, options: Int32) -> Self

    /// Empty is the engine's own.
    func setCustomUserAgent(_ userAgent: String)

    func setPageZoom(_ zoom: Double)

    /// Answered by `didFind` for `request`.
    func find(_ text: String, backwards: Bool, caseSensitive: Bool, request: Int32)

    func clearFind()

    func cancelDownload(_ download: Int32)

    /// The answer to `didRequestPermission`.
    func answerPermission(_ request: Int32, granted: Bool)

    /// PNG bytes `width` points wide. Answered by `didSnapshot` or
    /// `didFailRequest`.
    func snapshot(_ width: Double, request: Int32)

    /// Everything sites kept in this page's store since `since`, seconds
    /// since 1970. Answered by `didCompleteRequest`.
    func removeData(since: Double, request: Int32)
}
```

Added to `WebContentDelegate`, called only for a page made by
`make(_:dataStore:options:)`:

```swift
@DynamicCallback("org.pureswift.web.WebContentDelegate", version: 2)
public protocol WebContentDelegate: AnyObject {

    // … version 1 …

    /// A page to load a new window in, made by this call with the engine's
    /// settings for it, or nil for this page.
    func newPage(_ content: WebContent, url: String) -> WebContent?

    /// Whether to download it. The host waits for the answer.
    func shouldDownload(_ content: WebContent, download: Int32, url: String,
                        suggestedName: String, mimeType: String, expectedLength: Int64) -> Bool

    func didChangeDownload(_ content: WebContent, download: Int32, received: Int64, expected: Int64)

    /// Done: the file is `path` in the app's caches.
    func didFinishDownload(_ content: WebContent, download: Int32, path: String)

    func didFailDownload(_ content: WebContent, download: Int32, error: Int32, message: String)

    /// `count` and `index` are -1 where the engine doesn't say.
    func didFind(_ content: WebContent, request: Int32, matchFound: Bool, count: Int32, index: Int32)

    func didChangeSecurity(_ content: WebContent, hasOnlySecureContent: Bool, certificateSummary: String)

    /// `kinds` bits: 1 camera, 2 microphone, 4 location. Answer with
    /// `answerPermission`.
    func didRequestPermission(_ content: WebContent, request: Int32, origin: String, kinds: Int32)

    func didSnapshot(_ content: WebContent, request: Int32, png: [UInt8])

    func didCompleteRequest(_ content: WebContent, request: Int32)

    /// A `WebError.Code` raw value.
    func didFailRequest(_ content: WebContent, request: Int32, error: Int32, message: String)
}
```

`WebFeatures` bits: 1 non-persistent stores, 2 remote content off, 4
page scripts off, 8 new pages, 16 downloads, 32 find, 64 the find bar,
128 permissions, 256 snapshots, 512 removing data, 1024 security,
2048 user agent and zoom. A guest-side call a host doesn't honor fails
with `WebError.Code.unavailable`, a new code, 8.

`WebsiteDataStore.removeData` makes a page of that store, unseen, to
call it on, and lets it go when the host answers.

### The render IR

`WebView` gains props, and its first event:

| Prop | |
|---|---|
| `findNavigator` | bool: the platform's find bar is showing. When the user closes it, send `change` with `false` |
| `backForwardGestures` | bool |
| `magnificationGestures` | bool |

A host without them shows none, and a page without its find bar.

### For a host

- **`features()`** says what this host does. Say a bit only when it's
  done in full: a guest relies on remote content off to keep a mail
  message private.
- **A page made by `make(_:dataStore:options:)`** has a version 2
  delegate. Call version 2 methods on no other page's delegate.
- **Data stores:** 0 is the app's persistent store. Each other number is
  a non-persistent store, made when a page first names it and let go
  when no page does.
- **New windows:** when the engine asks for a view for a new window, call
  `newPage`. While that call runs, a page the guest makes is made with
  the engine's configuration for the window. Load the window in the page
  it returns, or in this one for nil.
- **Downloads** go to `Downloads/` in the app's caches, under the
  suggested name made unique. Report progress no more than ten times a
  second.
- **Permissions:** refuse without asking for a kind whose capability the
  app's manifest lacks. Otherwise call `didRequestPermission` and wait
  for `answerPermission`; an unanswered request is refused when its page
  goes.

What each platform has. These are from what's known of each, and
haven't been checked against its documentation yet:

| | iOS / macOS (`WKWebView`) | Android (`WebView`) | Linux (WPE) |
|---|---|---|---|
| Non-persistent store | `WKWebsiteDataStore.nonPersistent()` | `ProfileStore` profiles (WebView 1.13+), else not honored | an ephemeral `WebKitNetworkSession` |
| Remote content off | a `WKContentRuleList` blocking `http` and `https`, as without `.network` | `setBlockNetworkLoads(true)` | the `decide-policy` and `resource-load-started` signals |
| Page scripts off | `WKWebpagePreferences.allowsContentJavaScript` | `setJavaScriptEnabled(false)`, which stops the app's scripts too | `enable-javascript-markup` off |
| New windows | `WKUIDelegate.createWebViewWith` | `onCreateWindow` with `setSupportMultipleWindows(true)` | the `create` signal |
| Downloads | `WKDownload` (iOS 14.5, macOS 11.3) | `DownloadListener`; the host fetches the file itself | `download-started` |
| Uploads | the system's picker (iOS); `runOpenPanelWith` (macOS) | `onShowFileChooser` | `run-file-chooser`, through the file chooser portal |
| Find | `find(_:configuration:)` (iOS 16, macOS 13); `findInteraction` for the bar | `findAllAsync`, `FindListener` | `WebKitFindController` |
| Security | `hasOnlySecureContent`, `serverTrust` | `getCertificate()`, `onReceivedSslError` | `get_tls_info` |
| Permissions | `requestMediaCapturePermissionFor` (iOS 15, macOS 12); location is the system's own prompt and isn't asked | `onPermissionRequest`, `onGeolocationPermissionsShowPrompt` | `permission-request` |
| Snapshot | `takeSnapshot(with:)` | drawing the view into a `Bitmap` | `get_snapshot` |
| Removing data | `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` | `WebStorage`, `CookieManager`, `clearCache`; everything, whatever the date | `webkit_website_data_manager_clear` |
| User agent, zoom | `customUserAgent`, `pageZoom` | `setUserAgentString`, `setTextZoom` | `user-agent` setting, `zoom-level` |
| Gestures | `allowsBackForwardNavigationGestures`, `allowsMagnification` | none for history; `setBuiltInZoomControls` | the host's own |

### Tests and an example

- **`DynamicWebKit`:** the new methods' keys, `WebPage(configuration:)`
  nil when the host lacks a feature, and each feature through a stand-in
  engine: new pages, downloads, find, permissions, snapshots, removing
  data, security, the find bar's prop and event, and that a version 1
  page's delegate is never told version 2 events.
- **`ExampleWeb`** gains tabs (a link that opens a window opens one), a
  private tab, find, a download list, a camera permission it asks the
  user about, tab pictures, and a message page with remote content off.
  On the three engines, against the test's stand-in.

### Changed while building

- **`onPermissionRequest` instead of an async `permissionDecider`.** The
  app gets a `WebPermissionRequest` and calls `grant()` or `deny()` when
  the user answers, now or later. An app's own prompt is a view that
  answers later, which an async closure made awkward, and it works in
  guests built without concurrency.
- **`newPageHandler` takes the URL,** not a navigation: the engine says
  only the URL, and a navigation's kind would have been made up.
- **`removeData(since:)` takes seconds since 1970,** 0 by default: guest
  code has no Foundation `Date`. And it always asks an unseen page of the
  store, not one the app has.
- **`DynamicWebKit` links `DynamicFiles`,** for `WebDownload.file`, a
  `FilePath` in `.caches`. So a web app declares `Files` too; every host
  has it.
- **The modifiers are `WebView`'s,** not every view's: they go right after
  `WebView(page)`. Apple's are environment values; the frontend's
  environment has no keys a module outside it can add.
- **`WebPage.hostFeatures` and `WebFeatures` are public,** so an app can
  leave out a Find button or private tabs where the host lacks them.
- **Gestures left `.automatic` send no prop,** and the host's default is
  off, as in version 1.
- **`newPage`'s answer reaches the host as a proxy** of the host's own
  page, as any contract object a guest hands back does. The host finds
  its page behind it as it does for other methods given its own objects
  (in process, `NativeRuntime.swiftObject(for:)`).
- **`WebDownload.cancel()` marks the download cancelled at once,** and the
  host reports nothing more about it. Releasing a page cancels its
  downloads, and fails its waiting finds and snapshots with `cancelled`.
- **A page made before `newPage` was called isn't loaded in:** it has a
  view of its own. The guest answers nil for it, and for the opener.
- **The draft's questions, as built:** dialogs, sign-in, uploads and the
  find bar are the platform's; the engine doesn't remember a site's
  permission, and an app that wants "always allow" keeps it by
  `WebPermissionRequest.origin`; an Android WebView without profiles
  leaves out `nonPersistentStores`, and the app offers no private tabs.

### What hosts still need

- **`features()`:** say each bit only when it's done in full.
- **`make(_:dataStore:options:)`:** a non-persistent store per number,
  made when a page first names it and let go when none does; the options'
  remote content, page scripts and uploads off. Call version 2 delegate
  methods only on pages it made.
- **New windows:** call `newPage` when the engine asks for a window's
  view, make a page asked for during the call with the engine's settings
  for it, and load the window in the page behind the proxy it returns.
- **Downloads:** ask `shouldDownload`, save under `Downloads/` in the
  app's caches with the suggested name made unique, report progress no
  more than ten times a second, and give the path from the caches
  directory in `didFinishDownload`.
- **Find, the security state, permissions, snapshots and removing data,**
  each answered by its delegate method for its request. Refuse a
  permission whose capability the manifest lacks without asking.
- **The node:** `findNavigator` with its `change` event,
  `backForwardGestures` and `magnificationGestures`.
- **Checking the platform table above** against each platform's
  documentation, which hasn't been done.

### Not in this version

- Messages from a page's scripts to the app.
- Choosing what a site may store, or reading its cookies.
- Saving a page as PDF or web archive, printing, and reader mode.
- Custom URL schemes served by the app.
- Extensions, content blockers the user adds, and autofill.

### Questions

The design was approved without answers to these; each is built as it
proposes (the last item of "Changed while building").

1. **Asking the app or the platform.** Dialogs, sign-in, uploads and the
   find bar are the platform's here. A browser that wants its own
   dialogs would need them asked of it, as Apple's `DialogPresenting`
   does. Is the platform's enough for now?
2. **A permission per site.** The engine doesn't remember a site's
   answer, and the platform asks the user once for the app. A browser
   that wants "always allow for this site" keeps it itself. Should the
   contract keep it instead?
3. **Android without profiles.** A private tab needs WebView 1.13's
   profiles. Older WebViews would have `features()` without bit 1, and
   no private tabs. Is that acceptable?

## For a host

A host implements `WebContent` like any contract, and its player draws a
page where a `WebView` node names it.

1. `make(_:)`: create the engine's view, off screen, and keep the delegate.
   Turn JavaScript on where it's off by default (Android).
2. When a `WebView` node appears whose `page` prop equals a page's
   `identifier()`, put that page's view there. When the node goes, take the
   view out and keep the page: it's still loaded, and may be shown again.
3. Report every change through the delegate, on the main thread. A new
   page has no URL, an empty title, and isn't loading.
4. Ask `shouldNavigate` before each navigation the page or the user starts,
   in any frame, and wait for the answer. Don't ask for the guest's own
   `load`, `loadHTML` and `loadResource`.
5. Destroy the engine's view when the guest releases the `WebContent`.

### The delegate, event by event

| When | Call |
|---|---|
| A load starts | `didChangeLoading(isLoading: true, progress:)`, then more as it goes |
| The main frame commits, a redirect is followed, or a script changes the URL (History API) | `didChangeURL` |
| The title changes | `didChangeTitle` |
| The history gains or loses an entry to go to | `didChangeHistory` |
| The main frame finishes | `didChangeLoading(isLoading: false, progress: 1)`, then `didFinishNavigation` |
| The main frame fails | `didFailNavigation`, then `didChangeLoading(isLoading: false, progress: 1)` |
| A script finishes | `didEvaluateJavaScript`, with its `request` |

A navigation the guest refused, or one that another replaced, isn't a
failure: report nothing but the loading state.

### Rules every host follows

- **Script results are JSON text:** `"2"`, `"\"Example\""`, `"[1,2]"`.
  `undefined`, functions and anything else JSON can't hold are `nil`. An
  exception's message goes in `error`.
- **Errors** map to `WebError.Code`: 2 network (no connection, host not
  found or unreachable), 3 timed out, 4 security (a bad certificate, or
  plain HTTP where the platform forbids it), 5 bad URL (malformed, an
  unhandled scheme, a missing bundle resource), 7 not permitted (below),
  0 anything else.
- **Without the `network` capability, a page stays off the network.** The
  host checks the app's capabilities, as it does for contracts that
  require one:
  - `load` of a remote URL isn't started: `didFailNavigation` with 7.
  - A navigation to a remote URL from a local page is refused the same
    way, without asking `shouldNavigate`.
  - Remote subresources (images, scripts, styles, `fetch`) don't load.
  - `loadHTML`, `loadResource`, and `about:` and `data:` URLs work.
- **`loadResource`** resolves the path in the app bundle's resources, as
  `Bundle` does, and lets the page read the files beside it and no others
  in the bundle.
- **New windows** (`target="_blank"`, `window.open`) load in the same
  page, after `shouldNavigate` agrees.
- **`alert`, `confirm` and `prompt`** show the platform's dialog. Engines
  drop them unless the host handles them.
- **Permission requests** from pages (camera, microphone, location) are
  refused.
- **Input** inside the node's bounds belongs to the page: pointers, keys,
  scrolling, text entry with the platform's keyboard.

### Per host

| | Engine | Notes |
|---|---|---|
| iOS 8+ / macOS | `WKWebView` | Without `network`: a `WKContentRuleList` that blocks `http` and `https` loads. `decidePolicyFor` answers `shouldNavigate`; observe `url`, `title`, `estimatedProgress`, `isLoading`, `canGoBack`, `canGoForward`. `evaluateJavaScript` returns objects: encode them as JSON, fragments allowed. `loadFileURL(_:allowingReadAccessTo:)` for resources. App Transport Security refuses plain HTTP: report `security`. |
| iOS 6 | `UIWebView` | No progress or history observing; report what its delegate gives. |
| Android | `android.webkit.WebView` | Without `network`: `setBlockNetworkLoads(true)`, which is also what the missing `INTERNET` permission gives. `shouldOverrideUrlLoading` answers `shouldNavigate` (it isn't called for `loadUrl`, as the contract wants). `doUpdateVisitedHistory` for URL changes, `WebChromeClient` for progress and title. `evaluateJavascript` already returns JSON. `WebViewAssetLoader` for resources. |
| Linux | WPE WebKit | Below. |
| Browser | `<iframe>` | A page from another origin can't be observed or scripted: only `load` and the `load` event work, and many sites refuse to be framed. `shouldNavigate` is never asked. |

### Linux: WPE

WPE is WebKit without a toolkit: it renders through a view backend into
buffers, which suits a player that draws its own scene.

- **Drawing.** Give each page an exportable view backend
  (`wpebackend-fdo`), which hands the host every frame as an EGL image.
  The player draws the latest one as a texture in the node's bounds and
  tells the backend the frame is done. Tell the backend the node's size in
  pixels whenever it changes.
- **Input.** The player forwards pointer, wheel, touch and key events
  inside the node to the backend (`wpe_view_backend_dispatch_…`), in the
  page's coordinates. The page has keyboard focus while it's the focused
  node.
- **The contract** maps onto `WebKitWebView`: `load-changed`, `load-failed`
  and `decide-policy` signals, and the `uri`, `title`,
  `estimated-load-progress` and `is-loading` properties.
  `webkit_web_view_evaluate_javascript` returns a JavaScriptCore value;
  `jsc_value_to_json` makes the result.
- **Without `network`** the sandbox has no network to reach, so remote
  loads fail by themselves; the host still answers a remote `load` with
  `notPermitted` itself, so the app gets the same error as elsewhere.
- **Resources.** The bundle is at `/app` in the sandbox, so `loadResource`
  is a `file:///app/resources/…` URL, with file access limited to that
  directory.
- **The sandbox** is the open question. WPE runs web content and
  networking in child processes of its own, and can sandbox them with
  bubblewrap. Inside the launcher's sandbox (§7.8: a PID namespace,
  seccomp, `no_new_privs`) those children must still start, and
  bubblewrap can't nest there. The launcher's seccomp filter and the
  capability's network namespace have to be checked against what the
  WebKit processes need.

## Capability

None is required: a help screen made of bundled HTML shouldn't need the
`INTERNET` permission. `network` is what lets a page reach the network,
and the host enforces its absence (above), since the contract's metadata
can only say "requires".

| Host | With `network` | Without |
|---|---|---|
| iOS / macOS | pages load remotely; App Transport Security still applies | the host blocks remote loads |
| Android | the `INTERNET` permission | no permission, and network loads blocked |
| Linux distro | the network namespace isn't unshared (§7.8) | no network to reach |

The packager knows the pairing (`OPTIONAL_CAPABILITIES` in
`Scripts/manifest.py`): an app with a web view that declares `network`
isn't warned that no contract requires it.

## Threading

Every delegate method runs on the main thread (§6.4). Hosts hop from the
engine's threads first. `shouldNavigate` is answered before it returns, so
the engine's policy callback must be one the host can answer from the main
thread.

## Example

`examples/ExampleWeb`: an address field, back, forward, reload and stop
around a `WebView`, the page's title and progress, a script that counts the
page's links, and a decider that refuses `tel:` and `mailto:`. Its tests
stand in for the engine, as `App.wasm` under WasmKit
(`Packages/RuntimeWasm`) and as a sealed native slice and wasm2c output
(`Packages/LinkedSlice`). On the Darwin host it loads https://swift.org/ in
`WKWebView` in the iOS Simulator.
