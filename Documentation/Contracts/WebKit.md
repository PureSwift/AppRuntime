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
browser) exist, tested against a stand-in for the engine.

Guest-side Swift: `WebPage`, the observable page app code uses; `WebView`,
the SwiftUI view; `WebNavigation`, `WebNavigationKind` and `WebError`.

The render IR gains one node, `WebView`, whose `page` prop is the host
page's `identifier()`. It has no events: everything about a page goes
through the contract.

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
