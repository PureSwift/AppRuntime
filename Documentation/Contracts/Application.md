# The application: opening URLs and keeping the screen awake

**Status:** reviewed and built on the guest side, with the shared host
side: the two methods and their defaults, `HostApplication`'s hooks, the
frontend's `Application` with `openURL`, `OpenURLAction`, `onOpenURL`,
`scenePhase` and `idleTimerDisabled`, `Link`'s `intercepts`, and
`ExampleUI`'s System tab on the three engines. No platform host opens a
URL or keeps the screen awake yet; "What hosts still need" is the list.

`Application` is a built-in contract (`DynamicRuntime.md` §7.4): the
app's lifecycle, memory warnings, and the URLs it's opened with. This
adds the two things the plan's "Application and the manifest" list still
lacks (`PlannedApps.md`):

- **Opening a URL from code,** in the app that handles it: a phone number
  from Contacts, a map from Weather, a page from anywhere. `Link` does it
  for a tap, in the host, and nothing does it for a button or a menu.
- **Keeping the screen awake,** while a video plays, a timer counts down
  in Clocks, or Maps navigates.

It also gives the SwiftUI frontend an `Application` of its own, which it
has never made. Through it a view reads `scenePhase` and receives the URLs
the app is opened with, in `onOpenURL`, as SwiftUI's do. Today an app has
to make an `Application` and its delegate itself to hear either.

| | iOS | macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| Open a URL | `UIApplication.open(_:)` | `NSWorkspace.open(_:)` | `startActivity` with `ACTION_VIEW` | the `OpenURI` portal, or `g_app_info_launch_default_for_uri` | `window.open` |
| Keep the screen awake | `isIdleTimerDisabled` | a `PreventUserIdleDisplaySleep` power assertion | `FLAG_KEEP_SCREEN_ON` on the window | the `Inhibit` portal, idle | `navigator.wakeLock.request("screen")` |

These names are from what's known of each platform, and haven't been
checked against its documentation yet.

## What shapes it

- **Still version 1.** Nothing is public yet, so no app or host depends on
  the contract as it is: the two methods are added to version 1, and no
  guest checks for them. Each still has a default that does nothing, so
  the host repos build against master unchanged until they implement it.
  `ApplicationDelegate` doesn't change: nothing new is called back.
- **Opening answers at once.** Each platform but iOS says synchronously
  whether it could open the URL: there's an app for it, or there isn't.
  iOS answers in a completion handler. Waiting for it would need a new
  delegate method, and a host repo's default, which can't reach the
  delegate, would leave the guest waiting for ever. So `openURL` returns
  a `Bool`, and on iOS `true` means the system was asked.
- **The screen is kept awake by the app, not by a view.** The contract
  takes one switch for the app. The frontend counts the views that ask
  for it, so two on screen don't turn it off for each other.
- **The frontend owns an `Application`.** The Darwin host gives a URL that
  arrived before any `Application` existed to the first one made. If the
  frontend made one only when a view first opened a URL, a URL at launch
  would be lost, or would reach an app's own `Application` some times and
  not others. So it makes one when the app starts, before the first tree,
  and holds URLs until a view takes them.

## For a guest

```swift
import SwiftUI

struct ContactView: View {

    @Environment(.openURL) var openURL

    @Environment(.scenePhase) var scenePhase

    var body: some View {
        VStack {
            Button("Call") { openURL("tel:5551234") }
            Button("Directions") {
                openURL("https://maps.apple.com/?daddr=Cupertino") { accepted in
                    if !accepted { showNoMapsAlert() }
                }
            }
            Link("Website", destination: "https://example.com")
        }
    }
}

// Links in this subtree go through the app first.
ContentView()
    .environment(.openURL, OpenURLAction { url in
        if url.hasPrefix("exampleui:") {
            router.show(url)
            return .handled
        }
        return .systemAction
    })
    // The URLs the app is opened with: a deep link, a custom scheme.
    .onOpenURL { url in router.show(url) }

// While this view is on screen, the screen doesn't dim or lock.
VideoPlayer(player: player)
    .idleTimerDisabled(player.isPlaying)
```

- **`@Environment(.openURL)`** is an `OpenURLAction`, called as
  `openURL(url)` or `openURL(url) { accepted in … }`. By default it asks
  the host, and `accepted` is the host's answer. On a host that hasn't
  implemented it yet, nothing opens and `accepted` is `false`.
- **`OpenURLAction { url in … }`** in `environment(.openURL, _:)` sees
  each URL first, from code and from a `Link` below it, and returns:
  - `.handled`: the app did it; `accepted` is `true`.
  - `.discarded`: nothing opens; `accepted` is `false`.
  - `.systemAction`: the host opens it, as with no action.
  - `.systemAction(otherURL)`: the host opens `otherURL` instead.

  An action set lower in the tree comes first, and its `.systemAction`
  goes to the one above it, as in SwiftUI. URLs are strings, as `Link`'s
  are: guest code has no Foundation.
- **`onOpenURL { url in … }`** gets each URL the app is opened with,
  while the view is on screen. Every view on screen with one gets it. A
  URL that arrives while none is on screen, such as the one that launched
  the app, waits for the first that appears.
- **`@Environment(.scenePhase)`** is `.active`, `.inactive` or
  `.background`, from `Application`'s state, and the view updates when it
  changes. It's the app's phase: the frontend has one window.
- **`idleTimerDisabled(_:)`,** `true` by default, keeps the screen awake
  while the view is on screen and the argument is true. The name is
  UIKit's; SwiftUI has no modifier for it. The host lets the screen sleep
  again while the app isn't in the foreground, as the platforms do.

## The contract

```swift
@DynamicRuntime("org.pureswift.runtime.Application")
public protocol Application: AnyObject {

    static func make(_ delegate: ApplicationDelegate) throws(RuntimeError) -> Self

    func state() throws(RuntimeError) -> Int32

    /// Asks the platform to open `url` in the app that
    /// handles it. Whether it could: there's an app for it, and the URL is
    /// well formed. On iOS, whether the system was asked; its answer comes
    /// later, and isn't passed on. Default: `false`.
    func openURL(_ url: String) -> Bool

    /// While true, the screen doesn't dim or lock for
    /// want of input, while the app is in the foreground. Default: nothing.
    func setIdleTimerDisabled(_ disabled: Bool)
}
```

`BuiltinContracts.application` in `RuntimeABI` gains the two methods,
`openURL:` (`(O)Z`) and `setIdleTimerDisabled:` (`(Z)V`), and stays at
version 1.

## The render IR

`Link` gains a prop and its first event:

| Prop | |
|---|---|
| `intercepts` | bool: on a tap, send `tap` and open nothing. The guest opens the URL if its `OpenURLAction` says to |

The frontend sets it only under an `OpenURLAction` of the app's own. A
host that doesn't know the prop opens the URL itself, and the action isn't
asked: a browser app's links would leave it. Every renderer is to know
it; there are no older hosts to allow for.

## For a host

- **`openURL`:** hand the URL to the platform, and answer whether it took
  it. Refuse a URL that names a file: a guest can't name one outside its
  container, and one inside it is for `Documents`' share or export.
- **`setIdleTimerDisabled`:** the app's switch, the last call wins. Several
  `Application`s may be alive; the screen stays awake while any of them
  says so. Let it sleep while the app is in the background, and keep it
  awake again when it returns.
- **`Link` with `intercepts`:** send `tap`, open nothing.

### The shared host

`HostApplication`, which the Android and Linux hosts use, gains two hooks
the platform host sets, and does the rest:

```swift
/// Opens a URL in the app that handles it; whether it could.
nonisolated(unsafe) public static var openURL: ((String) -> Bool)?

/// Called when whether the screen should stay awake changes: any
/// `Application` asks, and the app is in the foreground.
nonisolated(unsafe) public static var idleTimerDisabledChanged: ((Bool) -> Void)?
```

Without `openURL`, a URL isn't opened and the answer is `false`. The
Darwin host implements `Application` itself (DarwinAppRuntime's
`DarwinApplication`), so it implements both methods there.

## Tests and an example

- **`DynamicRuntimeTests` and `RuntimeHostTests`:** the built-in
  the built-in descriptor with the two methods, and the generated one
  agreeing;
  `HostApplication` opening through its hook and answering `false`
  without one, and keeping the screen awake while any `Application` asks
  and the app is in the foreground.
- **`DynamicSwiftUITests`,** against a stand-in `Application` through
  `NativeRuntime`: `openURL` and its answer, an action's four results and
  their order through nested actions, a `Link`'s `intercepts` and its
  `tap`, `onOpenURL` with a URL held until a view takes it, `scenePhase`
  following the state, `idleTimerDisabled` counted across views and
  turned off when the last goes, and a host with only the defaults.
- **`ExampleUI`** gains a "System" section: a button that opens a URL and
  shows the answer, a `Link` the app handles itself, the last URL the app
  was opened with, the scene phase, and a switch that keeps the screen
  awake. On the three engines, against a stand-in host.

## Changed while building

- **`OpenURLAction.Result` is a struct with static members,** as
  SwiftUI's is: an enum can't have both `systemAction` and
  `systemAction(_:)`.
- **The frontend makes its `Application` only where the host has one.**
  `HostRenderer.start` makes it before the first tree; where making it
  fails, `openURL` answers `false` and the phase stays `.active`.
- **A URL held for a later `onOpenURL` is answered `true`** to the host:
  the app takes it, once a view is there to.
- **A state the guest doesn't know is ignored,** as a newer host's might
  be, and `ScenePhase` is `Comparable`, `.background` first, as SwiftUI's
  is.
- **`HostApplication` refuses a `file:` URL itself,** before its hook, and
  says what it last told the platform in `isIdleTimerDisabled`.
- **The draft's questions, as built:** `Link` has `intercepts`; the
  modifier is `idleTimerDisabled(_:)`; `openURL` answers at once.

## What hosts still need

- **The Darwin host:** `DarwinApplication` implements `openURL`
  (`UIApplication.open`, `NSWorkspace.open`) and `setIdleTimerDisabled`
  (`isIdleTimerDisabled`, a power assertion on macOS).
- **The Android and Linux hosts:** set `HostApplication.openURL` and
  `HostApplication.idleTimerDisabledChanged` to the platform's.
- **Every renderer:** a `Link` with `intercepts` sends `tap` and opens
  nothing.
- **Checking the table at the top** against each platform's
  documentation, which hasn't been done.

## Not in this design

- **Asking whether a URL can be opened** before opening it
  (`canOpenURL`). iOS answers it only for schemes the app lists in its
  `Info.plist`, which the manifest has no field for.
- **Opening a URL in the app's own browser view**
  (`SFSafariViewController`, Custom Tabs). That's `WebKit`'s, or the
  sign-in session's.
- **Universal links and app links,** which need a domain the app owns.
  The manifest's URL schemes are what's routed today.
- **More than one window,** and a phase per window.
- **Keeping the device awake with the screen off,** for work in the
  background: that's `BackgroundTasks`'.

## Questions

1. **The `Link` prop.** Without `intercepts`, an `OpenURLAction` sees
   only the URLs code opens, not a `Link`'s. With it, every renderer
   sends a `tap` for one. Is it worth it now, or should links stay the host's until a
   browser app needs them?
2. **The modifier's name.** `idleTimerDisabled(_:)` is UIKit's property
   name, and SwiftUI has nothing. `keepsScreenAwake(_:)` says what it does
   on every platform. Which?
3. **iOS's answer.** `true` there means the system was asked, not that an
   app opened the URL. Is that enough, or should `openURL` answer later
   on every platform, with a delegate method? Then a host repo that only
   has the default never answers, until it implements `openURL`.
