# Notifications

**Status:** implemented in this repository: the guest side, and the part of
the host side every host written in Swift shares. No platform host shows a
notification yet; each needs a presenter ([For a host](#for-a-host)).

Module `DynamicNotifications`: telling the user something while the app
isn't in front. A notification shown now, one scheduled for later, the
buttons on it, what the user did with it, and a push from the app's
server. Permission for all of it is in one place.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `Notifications` | contract, `requires: .notifications` | `UNUserNotificationCenter` | `NotificationManager`, `AlarmManager` | the shell's notification service | `showNotification` in a service worker |
| `NotificationRecord` | contract: one notification, as asked for or as delivered | `UNNotificationRequest` | `Notification` | the service's record | `Notification` |
| `NotificationCallback` | callback: one operation's result | | | | |
| `NotificationsDelegate` | callback: delivered, and answered | `UNUserNotificationCenterDelegate` | the host's receivers | the service's signals | `notificationclick` |
| `PushNotifications` | contract, `requires: .notifications` | APNs | Firebase Cloud Messaging | the OS's push service | the Push API |
| `PushCallback`, `PushDelegate` | callbacks: a registration, and its changes | | | | |

Guest-side Swift, named as Apple's `UserNotifications` names them without
the `UN`:

- **`UserNotificationCenter`**: asks permission, schedules, lists and
  removes, and reports what the user did.
- **`NotificationContent`**, **`NotificationTrigger`**,
  **`NotificationRequest`**: what to show, and when.
- **`NotificationCategory`**, **`NotificationAction`**: a kind of
  notification, how it behaves and its buttons.
- **`NotificationResponse`**, **`DeliveredNotification`**: what came
  back.
- **`PushSubscription`**: where the app's server sends a push.
- `NotificationSettings`, `AuthorizationOptions`, `NotificationError`.

The render IR doesn't change.

Host-side Swift, in `RuntimeNotifications`: `HostNotifications`, both
contracts over a host's `NotificationPresenter`.

## What shapes it

- **The system shows them, not the app.** A notification is delivered
  when the app is closed, so the host and the system hold everything
  needed to show it and its buttons. The guest isn't running then.
- **One permission, asked once.** Every platform has a single answer to
  "may this app notify me", for local notifications and pushes alike.
  The differences are in what needs it ([Permission](#permission)).
- **A category is how a kind of notification behaves.** Android's users
  set sound and importance per channel, and a notification can't override
  them. So sound, importance and buttons belong to the category here, on
  every platform, and a notification only says what it's about.
- **What the user did may start the app.** The answer to a notification
  waits in the host until the app listens, as an opened document does.
- **A push address isn't one thing.** Apple gives a token, Google another
  kind, and the web an address with keys. The contract hands the app what
  the platform gave and says which service it's for; the app's server has
  to speak to each.
- **Nothing here runs the app in the background.** A notification can be
  scheduled, shown and tapped with the guest closed. Running guest code
  without bringing the app forward waits for the background contract
  ([Not in this design](#not-in-this-design)).

## Permission

Three things could need the user's leave. Only the first ever prompts.

| | To show a notification | To get a push address | Exact timing |
|---|---|---|---|
| iOS / macOS | one prompt, the first time the app asks | nothing asked. Needs the push entitlement | always exact |
| Android | one prompt on Android 13 and later; granted before that | nothing asked. Needs Google Play services | a setting the user turns on, from Android 12; granted to alarm and calendar apps that declare it |
| Browser | one prompt, only during a user action | the same permission, granted first | no scheduling at all |
| Linux | the shell's own setting, per app | nothing asked | always exact |

The rules that follow from it:

1. **`settings()` never prompts.** It says where things stand.
2. **`requestAuthorization(_:)` prompts once.** After the user has
   answered, it answers the same without asking. Call it from a user
   action, at a moment the user understands why: a browser refuses
   otherwise with `notAllowed`.
3. **Ask before registering for push.** iOS and Android give an address
   without permission, and a browser won't. An app that asks first works
   everywhere. Without permission a push still reaches a running app on
   iOS and Android; it just can't be shown.
4. **Denied is final for the app.** No platform prompts twice. The app can
   say where the setting is, and `settings()` shows when it changes.
5. **Scheduling isn't refused for want of exact timing.** Without it
   Android delivers late, by minutes, and longer while the device sleeps.
   An alarm clock asks for it; a reminder app needn't.

`Permissions.status(.notifications)` and `Permissions.request` (§7.4) are
the same permission with the default options. iOS only reports its status
asynchronously, so a host keeps the last answer for the built-in's
synchronous `status`, and `settings()` asks afresh.

### For a guest

```swift
import DynamicNotifications

let center = UserNotificationCenter.current

// From a button, such as "Remind me".
let status = try await center.requestAuthorization([.alert, .sound, .badge])
guard status == .granted || status == .limited else { return }

let settings = try await center.settings()
if !settings.exactTiming {
    // An alarm clock: sends the user to the setting, and answers when
    // they come back.
    _ = try await center.requestExactTiming()
}
```

| `NotificationSettings` | |
|---|---|
| `authorizationStatus` | a `PermissionStatus` (§7.4): `notDetermined`, `denied`, `granted`, `limited` for quiet delivery, `restricted`, `unavailable` |
| `alerts`, `sounds`, `badges` | what the user left on |
| `exactTiming` | whether a scheduled notification arrives on time |
| `deliversWhenClosed` | whether a scheduled notification arrives with the app closed. False in a browser |

| `AuthorizationOptions` | |
|---|---|
| `.alert`, `.sound`, `.badge` | what the app means to use. iOS shows them in its prompt; Android and a browser grant all or nothing |
| `.provisional` | deliver quietly without asking, where the platform can (iOS). The status is then `limited`. Elsewhere it asks as usual |

## Showing and scheduling

```swift
var content = NotificationContent()
content.title = "Tea"
content.body = "Your timer is done."
content.categoryIdentifier = "timer"
content.userInfo = ["timer": "42"]

// In five minutes.
try await center.add(NotificationRequest(
    identifier: "timer-42", content: content, trigger: .timeInterval(300)))

// Now.
try await center.add(NotificationRequest(identifier: "done", content: content))

// Every weekday morning needs one request a day: Monday at 7:00.
try await center.add(NotificationRequest(
    identifier: "alarm-mon", content: content,
    trigger: .calendar(hour: 7, minute: 0, weekday: 2, repeats: true)))
```

| `NotificationContent` | |
|---|---|
| `title`, `subtitle`, `body` | the text, already in the user's language |
| `categoryIdentifier` | which category it's of. None: the default one |
| `threadIdentifier` | notifications with the same one are grouped |
| `badge` | the number on the app's icon once it's delivered. `nil`: unchanged |
| `isSilent` | delivered without sound, whatever its category says |
| `userInfo` | `[String: String]`, handed back with the response |

| `NotificationTrigger` | Fires |
|---|---|
| none | now |
| `.timeInterval(_:repeats:)` | after so many seconds. Repeating needs 60 or more |
| `.date(millisecondsSince1970:)` | once, at that moment |
| `.calendar(year:month:day:hour:minute:second:weekday:repeats:)` | when the device's clock next matches the parts given, in its own time zone. Repeating: every time it does |

- **An identifier names one notification.** Adding a request with an
  identifier in use replaces the one before, pending or delivered.
- **The system keeps a scheduled request.** It fires with the app closed,
  and after the device restarts.
- **A host keeps at least 64 pending requests**, which is all iOS keeps.
  Past its limit `add` fails with `limitReached`.
- **A moment that has passed** fails with `invalid`, and so does a
  repeating interval under 60 seconds.
- **`weekday`** is 1 for Sunday to 7 for Saturday, as Foundation's is.

Managing what's there:

| `UserNotificationCenter` | |
|---|---|
| `pendingIdentifiers()` | scheduled and not yet delivered |
| `deliveredIdentifiers()` | delivered and still in the system's list |
| `removePending(_:)`, `removeAllPending()` | cancels them |
| `removeDelivered(_:)`, `removeAllDelivered()` | takes them out of the list |
| `setBadgeCount(_:)` | the number on the app's icon; 0 clears it. Where the platform has no number, nothing |

## Categories and actions

```swift
center.setCategories([
    NotificationCategory(
        identifier: "timer", name: "Timers",
        actions: [
            NotificationAction(identifier: "repeat", title: "Repeat"),
            NotificationAction(identifier: "stop", title: "Stop", options: .destructive),
        ],
        interruption: .timeSensitive, sound: .named("chime.wav")),
    NotificationCategory(
        identifier: "message", name: "Messages",
        actions: [.textInput(identifier: "reply", title: "Reply", buttonTitle: "Send", placeholder: "Message")]),
])
```

| `NotificationCategory` | |
|---|---|
| `identifier` | what `categoryIdentifier` and a push name |
| `name` | what the user sees it called in the system's settings |
| `actions` | its buttons, in order. Hosts show at least two |
| `interruption` | `.passive` (in the list, no sound or banner), `.active` (the default), `.timeSensitive` (through a focus or do-not-disturb, where the user allows) |
| `sound` | `.default`, `.none`, or `.named(_:)`: a sound file in the bundle |

- **Set them at every launch,** before anything else. They replace the
  ones before.
- **On Android a category is a channel.** The user can change its sound
  and importance in Settings, and after it first exists the app can't:
  registering again updates only its name and buttons.
- **A notification with no category** is of a default one the host makes,
  named for the app, `.active`, with the default sound.
- **Every action opens the app.** It comes forward and the response is
  delivered. A button that works without opening the app is with the
  background contract.
- **A text action** hands back what the user typed. Where a host can't
  take text in a notification (most browsers), the action opens the app
  with no text.

## What the user did

```swift
for await response in center.responses {
    let timer = response.notification.userInfo["timer"]
    switch response.actionIdentifier {
    case NotificationAction.defaultIdentifier: show(timer)       // tapped the notification
    case "repeat": restart(timer)
    case "reply": send(response.text ?? "")
    default: break
    }
}
```

- `responses` is an `EventStream<NotificationResponse, Never>`. **The
  response that started the app waits** in the host until the app first
  reads it.
- `center.onResponse { … }` is the same with a closure. One listener at a
  time.
- A `DeliveredNotification` has the request's `identifier`, its content,
  `isRemote` for a push, and when it was delivered.

### While the app is open

```swift
center.foregroundPresentation = []          // the app shows it itself
for await notification in center.received { … }
```

- **A notification that arrives while the app is in front is shown as
  usual** unless the app says otherwise. `foregroundPresentation` is
  `[.banner, .list, .sound, .badge]` to begin with.
- `received` reports each one that arrives while the app is running,
  local or pushed, shown or not. `center.onReceive { … }` is the closure
  form.

## Push

```swift
let subscription = try await center.registerForRemoteNotifications(
    applicationServerKey: "BEl62i…")        // for Web Push; ignored elsewhere
await server.register(subscription)

for await changed in center.subscriptionChanges {
    await server.register(changed)
}
```

| `PushSubscription` | |
|---|---|
| `service` | `.apns`, `.fcm` or `.webPush`: which service the address is for |
| `address` | the APNs device token in hex, the FCM registration token, or the Web Push endpoint URL |
| `publicKey`, `authSecret` | Web Push's `p256dh` and `auth` keys, base64url. `nil` elsewhere |
| `isDevelopment` | APNs's sandbox, for a development build |

- **Register at every launch.** It's cheap, and the address can change.
  `subscriptionChanges` reports a change while the app runs.
- **The app's server speaks to each service.** Nothing here hides APNs,
  FCM and Web Push from it; `service` says which one to use.
- **The manifest declares push:** `.notifications(remote: true)`. Without
  it registering fails with `notDeclared`, and the packager refuses an
  app that uses `PushNotifications`.
- **`unregisterForRemoteNotifications()`** stops pushes to this install.

### What a push does

| The app is | A push that shows something | A push with data only |
|---|---|---|
| closed, or in the background | the system shows it. A tap arrives in `responses` | not delivered to the guest |
| running | arrives in `received`, and is shown as `foregroundPresentation` says | arrives in `received` |

A push's category, thread and badge work as a local notification's do,
and its custom values arrive in `userInfo`. A value that isn't a string
arrives as its JSON text.

### What the server sends

Each service has its own message. For a push to show the same thing
everywhere:

| Service | The notification | Custom values |
|---|---|---|
| APNs | the `aps` dictionary: `alert` (`title`, `subtitle`, `body`), `badge`, `category`, `thread-id`. iOS shows it without the host | the other top-level keys |
| FCM | a data message, with the keys below. The host builds the notification, so its category's buttons are there | the other keys in `data` |
| Web Push | a JSON body with the keys below. The host's service worker shows it | the `data` object |

The keys a host reads, on Android and in a browser:

| Key | |
|---|---|
| `rt.title`, `rt.subtitle`, `rt.body` | the text. With none of them, nothing is shown |
| `rt.category`, `rt.thread` | as the content's |
| `rt.badge` | a number |
| `rt.identifier` | replaces a delivered notification with the same one |

An FCM message with a `notification` block also works: Android shows it
itself while the app is closed, in the channel the message names, and
without buttons.

## The contracts

```swift
@DynamicRuntime("org.pureswift.notifications.Notifications", requires: .notifications)
protocol Notifications {
    static func current() -> Self

    func settings(_ callback: NotificationCallback)                                  // didGetSettings
    /// `options`: bits of `AuthorizationOptions`.
    func requestAuthorization(_ options: Int32, callback: NotificationCallback)      // didGetSettings
    func requestExactTiming(_ callback: NotificationCallback)                        // didGetSettings

    // Categories, set together: begin, each one and its buttons, end.
    func beginCategories()
    /// `interruption`: 0 passive, 1 active, 2 time-sensitive.
    /// `sound`: 0 default, 1 none, 2 the bundle's file `soundName`.
    func addCategory(_ identifier: String, name: String, interruption: Int32, sound: Int32, soundName: String?)
    /// `options`: bits, 1 destructive, 2 needs the device unlocked.
    func addAction(_ category: String, identifier: String, title: String, options: Int32)
    func addTextAction(_ category: String, identifier: String, title: String, options: Int32, buttonTitle: String, placeholder: String)
    func endCategories()

    func add(_ notification: NotificationRecord, callback: NotificationCallback)     // didComplete
    func pending(_ callback: NotificationCallback)                                   // didList
    func delivered(_ callback: NotificationCallback)                                 // didList
    func removePending(_ identifiers: [String])
    func removeAllPending()
    func removeDelivered(_ identifiers: [String])
    func removeAllDelivered()
    func setBadgeCount(_ count: Int32)

    /// Bits: 1 banner, 2 list, 4 sound, 8 badge.
    func setForegroundPresentation(_ options: Int32)
    /// The host keeps a response that arrives while there's no delegate.
    func setDelegate(_ delegate: NotificationsDelegate?)
}

@DynamicRuntime("org.pureswift.notifications.Record")
protocol NotificationRecord {
    static func make(_ identifier: String) -> Self
    func identifier() -> String

    func setTitle(_ title: String);        func title() -> String
    func setSubtitle(_ subtitle: String);  func subtitle() -> String
    func setBody(_ body: String);          func body() -> String
    func setCategory(_ identifier: String?);  func category() -> String?
    func setThread(_ identifier: String?);    func thread() -> String?
    /// −1: leave the badge as it is.
    func setBadge(_ count: Int32);         func badge() -> Int32
    func setSilent(_ silent: Bool);        func isSilent() -> Bool
    func setValue(_ value: String?, forKey key: String)
    func keys() -> [String];               func value(_ key: String) -> String?

    // One trigger; none means now.
    func setInterval(_ seconds: Double, repeats: Bool)
    func setDate(_ milliseconds: Int64)
    /// −1 for a part that isn't given.
    func setCalendar(_ year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32, repeats: Bool)

    // The trigger, for the host to read.
    /// 0 none, 1 an interval, 2 a date, 3 calendar parts.
    func triggerKind() -> Int32
    func triggerRepeats() -> Bool
    func triggerInterval() -> Double
    func triggerDate() -> Int64
    /// 0 the year, then month, day, hour, minute, second, and 6 the weekday.
    func triggerPart(_ index: Int32) -> Int32

    // Of a delivered one.
    func isRemote() -> Bool
    /// Milliseconds since 1970 UTC; 0 before it's delivered.
    func delivered() -> Int64
}

@DynamicCallback("org.pureswift.notifications.Callback")
protocol NotificationCallback {
    func didComplete()
    /// `status`: a `PermissionStatus`. `enabled`: bits, 1 alerts, 2 sounds,
    /// 4 badges, 8 exact timing, 16 delivers when closed.
    func didGetSettings(_ status: Int32, enabled: Int32)
    func didList(_ identifiers: [String])
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.notifications.Delegate")
protocol NotificationsDelegate {
    /// Delivered while the app is running.
    func didReceive(_ notification: NotificationRecord)
    /// `action`: empty for the notification itself. `text`: a text action's.
    func didRespond(_ notification: NotificationRecord, action: String, text: String?)
}

@DynamicRuntime("org.pureswift.notifications.Push", requires: .notifications)
protocol PushNotifications {
    static func shared() -> Self
    /// `serverKey`: Web Push's application server key, base64url.
    func register(_ serverKey: String?, callback: PushCallback)                      // didRegister
    func unregister(_ callback: PushCallback)                                        // didComplete
    func setDelegate(_ delegate: PushDelegate?)
}

@DynamicCallback("org.pureswift.notifications.PushCallback")
protocol PushCallback {
    /// `service`: 0 APNs, 1 FCM, 2 Web Push.
    func didRegister(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool)
    func didComplete()
    func didFail(_ error: Int32)
}

@DynamicCallback("org.pureswift.notifications.PushDelegate")
protocol PushDelegate {
    func didChangeRegistration(_ service: Int32, address: String, publicKey: String?, authSecret: String?, development: Bool)
}
```

Two contracts, so the packager knows from an app's contract list whether
it uses push.

A host reads a record the guest made through the record's own methods:
what the guest hands back is its proxy, not the host's object. That's why
a record can say its trigger, and why categories are calls on
`Notifications` and not objects.

### Rules every host follows

- **One callback object per operation**, held until exactly one of its
  methods is called, on the main thread.
- **The guest needn't be running.** A scheduled notification is shown,
  and a push that shows something is shown, by the host's own code or the
  system's.
- **A response opens the app** and is delivered once, to the delegate, or
  to the first one set after it.
- **A record is read when it's added.** Changing it afterwards changes
  nothing; add it again to replace the notification.
- **Without permission, `add` fails** with `notAuthorized`, where the
  platform would drop the notification silently.
- **Categories are kept by the host across launches,** so a push that
  arrives with the app closed has its buttons.
- **`userInfo` comes back as it went in.** A host keeps at least 4 KB of
  it per notification.
- **An unknown category** is the default one.
- **Calendar parts are local time,** and follow the device's time zone
  when it changes.

### Errors

`NotificationError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only, a cancelled task |
| 2 | `notAuthorized`: the user hasn't allowed notifications |
| 3 | `notAllowed`: not called from a user action |
| 4 | `unsupported`: this host can't, such as push with no push service |
| 5 | `invalid`: a moment that has passed, a repeating interval under 60 seconds, calendar parts that match no date |
| 6 | `limitReached`: the host keeps no more pending requests |
| 7 | `notDeclared`: push, and the manifest doesn't say `remote` |
| 8 | `unavailable`: the push service can't be reached now |

## The manifest

```swift
capabilities: [
    .notifications(remote: true, exactTiming: true),
]
```

There's no usage text: no platform shows one in its prompt.

| | `.notifications` | with `remote` | with `exactTiming` |
|---|---|---|---|
| iOS / macOS | nothing | the `aps-environment` entitlement | nothing |
| Android | `POST_NOTIFICATIONS`, and `RECEIVE_BOOT_COMPLETED` to schedule again after a restart | the Firebase messaging service, and the app's `google-services.json` | `USE_EXACT_ALARM`, which Google Play allows alarm and calendar apps; `SCHEDULE_EXACT_ALARM` otherwise |
| Linux | the notification service's socket, bound into the sandbox | the push service's | nothing |
| Browser | a service worker | the same | nothing |

The Firebase configuration is Android's alone, so it goes in
`AndroidSettings`: `android: .init(googleServices: "google-services.json")`.
The packager copies the file into the bundle under that name.

The options reach a host in the bundle's `Info.plist`, as
`RTCapabilityOptions.notifications`: `remote` and `exactTiming`, each
`"true"` when set. The packager refuses an app that uses
`PushNotifications` without `remote`, and warns about `remote` on Android
with no `googleServices`.

## For a host

A host written in Swift implements `NotificationPresenter`, and
`HostNotifications` does the rest:

```swift
final class MyCentre: NotificationPresenter {
    func settings(_ completion: @escaping (NotificationSettings) -> Void) { … }
    func requestAuthorization(_ options: AuthorizationOptions, completion: …) { … }
    func setCategories(_ categories: [NotificationCategory]) { … }
    func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void) { … }
    func pending(_ completion: @escaping ([String]) -> Void) { … }
    func delivered(_ completion: @escaping ([String]) -> Void) { … }
    func removePending(_ identifiers: [String]?) { … }       // nil: all
    func removeDelivered(_ identifiers: [String]?) { … }
    func setBadgeCount(_ count: Int) { … }
    func setForegroundPresentation(_ options: NotificationPresentationOptions) { … }
    // With defaults: requestExactTiming, registerForPush, unregisterForPush.
}

HostNotifications.presenter = MyCentre()
HostNotifications.declaresRemote = remoteIsInTheManifest
HostNotificationsModule.register(in: runtime)

// The user tapped a notification, or one of its buttons:
HostNotifications.responded(to: notification, action: "repeat")
// One arrived while the app runs:
HostNotifications.received(notification)
// The push address changed:
HostNotifications.pushSubscriptionChanged(subscription)
```

- **It checks each request before the presenter sees it:** an identifier,
  a moment that hasn't passed, a repeating interval of a minute or more,
  calendar parts a calendar can show. And it refuses one the user hasn't
  allowed, with `notAuthorized`.
- **It keeps what the user did** until the guest listens, so the response
  that started the app isn't lost.
- **It refuses push** with `notDeclared` unless the host says the manifest
  declares it.
- **It keeps the last status** the presenter reported, for the built-in
  `Permissions.status`, which can't wait. `HostNotifications.refreshStatus()`
  asks again: at launch, and when the app comes forward.
- **`HostNotificationTrigger.nextDate(after:calendar:)`** says when a
  trigger next fires, for a presenter that keeps time itself. A time the
  clocks skip when they go forward is the next one they show that day; 29
  February waits for a leap year.
- **Answers are delivered later,** on the main dispatch queue, or through
  `HostNotifications.deliver` for a host with a loop of its own.

The presenter still does the platform's part: showing, scheduling with
the app closed, the buttons, and the push service. Android and the browser
aren't written in Swift, and implement the contracts themselves.

## Per host

| | Notes |
|---|---|
| iOS / macOS | `UNUserNotificationCenter` throughout. Interruption and sound are copied from the category onto each request. `willPresent` answers with `foregroundPresentation`. Push is `registerForRemoteNotifications`; the token needs no prompt. |
| Android | The host posts with `NotificationManager`, one channel per category. A scheduled request is an `AlarmManager` alarm whose receiver posts it; requests are kept on disk and set again after a restart, and a repeating calendar trigger is set again each time it fires. Buttons are `PendingIntent`s that open the activity; a text action is `RemoteInput`. FCM's service builds a notification from a data message. No Google Play services: push is `unsupported`. |
| Linux | Below. |
| Browser | `Notification.requestPermission`, and `showNotification` on the host's service worker. Nothing is scheduled by the browser: the host fires scheduled requests from a timer while the page is open, and `deliversWhenClosed` is false. `notificationclick` opens or focuses the page and passes the response on. Push is `PushManager.subscribe`, which needs the permission and the server key. On iOS only a web app on the Home Screen can ask. |

### Linux

A sketch, for the Linux host's own design:

- **The shell runs the notification service.** An app with
  `.notifications` gets its socket.
- **It holds scheduled requests itself,** on disk, so they fire with the
  app closed and after a restart. This is the plan's alarm service.
- **It holds each app's categories,** and shows buttons.
- **A response starts the app** through launch services and waits for it
  to listen.
- **Permission is the shell's per-app setting.** Whether a new app is
  asked about, or allowed until the user says otherwise, is the shell's
  choice.
- **Push is undecided.** The fitting shape is Web Push: the OS keeps one
  connection and gives each app an endpoint and keys, so `service` is
  `.webPush` and an app's server needs nothing new. UnifiedPush works
  this way, as far as I know; to be confirmed against its specification.

A Flatpak app's notifications reach the same service through the portal
backend.

## Capability

`.notifications`, which both contracts require. It prompts when the app
asks ([Permission](#permission)), never by itself.

## Threading

Every callback and delegate method runs on the main thread (§6.4).

## Example and tests

`examples/ExampleNotifications`: kitchen timers. It asks the user's leave
from a button, schedules a notification for when each timer ends, lists
and cancels them, answers the notification's Repeat and Stop buttons, and
registers for pushes.

- `DynamicNotificationsTests`: the contracts' keys and signatures, and
  `UserNotificationCenter` against a scripted host.
- `RuntimeNotificationsTests`: `HostNotifications` over a notification
  centre the test keeps in memory, driven from the guest; and the
  triggers' arithmetic.
- The example runs against `HostNotifications` as `App.wasm` under
  WasmKit (`Packages/RuntimeWasm`), and as a sealed native slice and
  wasm2c output (`Packages/LinkedSlice`).

Everything is tested against a centre in memory. No notification has been
shown by a system, no push sent, and nothing here has been checked on a
device: the platform behaviour above is from each platform's
documentation.

## Not in this design

- **Running the app in the background:** a button that works without
  opening the app, time to finish work after a response, and a push with
  data only that wakes a closed app to sync. These need a guest started
  with no window, which the runtime can't do yet. They belong to the
  background contract, and mail and calendar sync wait for it.
- **An alarm that rings until it's answered.** A notification plays a
  sound once. A clock's alarm, which rings on, shows over the lock screen
  and ignores silent mode, is each platform's separate thing (AlarmKit on
  iOS 26, an alarm-clock alarm with a full-screen intent on Android). It
  wants a small contract of its own.
- **Pictures and other attachments.**
- **Hearing that a notification was dismissed.**
- **Critical alerts,** which need Apple's approval.
- **Location triggers.**
- **Localized keys in a push** (`loc-key`): a push carries its text.
- **Live activities, widgets and progress bars** in a notification.
- **Topics and groups** in a push service: the app's server does those.

## Decided in review

The design was approved as drafted, so these stand:

- **Names:** `DynamicNotifications`, `UserNotificationCenter`, and Apple's
  type names without `UN`. No aliases with `UN`.
- **A category is also Android's channel,** and carries the name, the
  importance and the sound.
- **Push is in the same module,** as a second contract.
- **The `rt.` keys** for a push on Android and the web.
- **Every action opens the app** until the background contract exists.

## Questions left

1. **Linux push as Web Push.** Nothing is built for it; it decides what
   the OS's push service is.
2. **Alarms.** The plan's Clocks app needs the separate alarm contract to
   ring properly. With this alone it can notify, and not ring on.
3. **A host-run "snooze" action,** which schedules the same notification
   again without the guest, would cover a clock's commonest button before
   the background contract exists.
