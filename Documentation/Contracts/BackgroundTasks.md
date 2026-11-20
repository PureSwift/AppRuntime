# Background tasks

**Status:** implemented in this repository: the guest side, and the part of
the host side every host written in Swift shares. No platform host runs
anything in the background yet; each needs a scheduler ([For a
host](#for-a-host)), and a renderer that can be made with no window.

Module `DynamicBackgroundTasks`: running the app's code while the app
isn't in front. Work the system starts from time to time, such as fetching
mail; and time to finish something when the user leaves, or when a
notification's button or a push arrives.

| Contract | Kind | iOS | Android | Linux | macOS | Browser |
|---|---|---|---|---|---|---|
| `BackgroundTasks` | contract, `requires: .backgroundTasks` | `BGTaskScheduler`; `beginBackgroundTask` | `WorkManager` | the OS's background service | `NSBackgroundActivityScheduler`, while the app is open | none |
| `BackgroundTasksDelegate` | callback: a task to run, and time running out | launch handlers | a `Worker` | the service's requests | the scheduler's block | |
| `BackgroundCallback` | callback: one operation's result | | | | | |

Guest-side Swift, named as Apple's `BackgroundTasks` names them without
the `BG`:

- **`BackgroundTaskScheduler`**: says what each task does, asks for runs,
  and holds the app awake to finish something.
- **`BackgroundTaskRequest`**: which task, how often, and what it needs.
- **`BackgroundTask`**: one run, to complete.
- **`BackgroundActivity`**: time the app asked for itself.
- `BackgroundError`.

It changes no ABI. A guest still has three exports.

Host-side Swift, in `RuntimeBackgroundTasks`: `HostBackgroundTasks`, the
contract over a host's `BackgroundScheduler`.

## What shapes it

- **A guest starts the same way, with or without a window.** The host
  calls `rt_main` as always. In the background the host's renderer keeps
  what the app sends and shows nothing; the window appears if the user
  opens the app. So nothing in a guest's start-up is new, and a slice's
  exports stay as they are ([Starting without a
  window](#starting-without-a-window)).
- **In the background, the app runs only while it holds an activity.**
  One the system began by running a task, or one the app began itself.
  With none, the host may stop the app at once. This one rule covers
  scheduled work, saving on the way out, a notification's button and a
  push.
- **The system decides when.** No platform runs background work on a
  schedule the app sets. A request says "no sooner than, and about this
  often"; the system picks the moment, from the battery, the network and
  how much the user opens the app. It may be hours late, and it may never
  come.
- **Time is short and can run out.** About half a minute for a refresh on
  iOS, about ten minutes on Android. The app is told when it's out of
  time, and must stop then.
- **What can run is declared.** iOS runs only tasks its `Info.plist`
  names, so the manifest lists them, and the list is the same everywhere.
- **Nothing here is exact.** A moment the user set is a notification
  ([Notifications](Notifications.md)), which the system delivers without
  running the app.

## For a guest

### A task the system runs

```swift
import DynamicBackgroundTasks

let scheduler = BackgroundTaskScheduler.shared

// In the app's init, every launch: what the task does.
scheduler.register("org.example.mail.sync") {
    try await mailbox.fetchNewMessages()
}

// When there's something to keep fresh, such as after sign-in:
try await scheduler.submit(BackgroundTaskRequest(
    "org.example.mail.sync", every: 30 * 60, requiresNetwork: true))
```

| `BackgroundTaskRequest` | |
|---|---|
| `identifier` | a task the manifest names |
| `kind` | `.refresh`, short and frequent (the default); `.processing`, long and rare, when the device is idle |
| `earliest` | seconds from now before which it won't run. 0: any time |
| `every` | seconds between runs, 900 or more. `nil`: once |
| `requiresNetwork`, `requiresCharging` | wait for these. A refresh on iOS can't ask for them; it's run when the system thinks best |

- **Register in the app's `init`, at every launch.** When the system
  starts the app to run a task, the handler must be there by the time
  `rt_main` returns. A run whose task has no handler fails.
- **The handler is `async`.** It returns when the work is done, and
  throws when it failed. When time runs out its task is cancelled:
  `Task.isCancelled` turns true, and awaited calls throw. It should then
  return quickly. A run that was cut short counts as failed.
- **A request replaces the one before** with the same identifier.
- **One refresh task is all iOS keeps pending,** and ten processing
  tasks. An app has one of each, as a rule.
- **`every` is how often at most.** The host asks again after each run.
- `cancel(_:)` and `cancelAll()` withdraw requests;
  `pendingIdentifiers()` lists them.

A completion-handler form, for code that isn't `async` and for slices
without the concurrency runtime:

```swift
scheduler.register("org.example.mail.sync") { (task: BackgroundTask) in
    task.onExpiration = { mailbox.stop() }
    mailbox.fetchNewMessages { ok in task.complete(success: ok) }
}
```

### Time the app asks for

```swift
// The user leaves while a draft is being saved.
let activity = scheduler.beginActivity("Saving draft")
try await drafts.save(draft)
activity.end()

// Or around a block:
try await scheduler.withActivity("Upload") {
    try await upload(photo)
}
```

- **`beginActivity` never fails.** Where the host can't keep the app
  running, the activity has already expired: `isExpired` is true, and the
  work goes on only while the system lets it.
- **It's short:** about 30 seconds on iOS. `timeRemaining` says how long,
  where the host knows.
- **`onExpiration`** is called when time is up. `withActivity` cancels
  its block's task then.
- **End every activity.** One that's released ends too.
- **It's for finishing, not for staying.** Something that goes on for
  minutes is a scheduled task, a background transfer, or playback.

### Whether it can run at all

```swift
switch scheduler.status {
case .granted: break
case .denied: showHowToTurnItOn()      // the user turned it off for this app
default: break                         // restricted, or this host has none
}
```

`status` is a `PermissionStatus` (§7.4). Nothing prompts for it on any
platform: it's a switch in the system's settings, on by default. A request
made while it's off is kept, and runs if it's turned on.

## Starting without a window

The system starts a closed app to run a task. On every host that is the
same start as when the user opens it:

1. The host loads the slice and calls `rt_main`.
2. The app's `init` runs: it registers its tasks, sets its notification
   categories, and whatever else it does at launch.
3. `App.run()` makes the host's `Renderer` and sends its first tree. The
   host has no window, so it keeps the tree.
4. `rt_main` returns. The host calls the task's handler.
5. When the handler has finished and no activity is held, the host may
   stop the app.

If the user opens the app while it's running, the host makes the window
and shows the tree it has. `Application.state()` is `.background` until
then, and the delegate hears `.active`.

- **An app that wants to do less at a background start** reads
  `Application.state()` in its `init`.
- **Nothing is saved for it.** A stopped app starts from `rt_main` next
  time, as any launch does.
- **No frame is drawn in the background.** A `Surface` isn't asked for
  frames, as whenever the app isn't active (§8).

This asks one thing of every host: a `Renderer` that can be made before
there's a window. Whether each host's can today wasn't checked. Nothing in
the guest or its frontend changed for it, and the tests' renderer, which
has no window at all, is how the example runs.

## What it adds to notifications

[Notifications](Notifications.md) left two things for this contract. With
it, both work by the rule above:

- **A button that doesn't open the app.** `NotificationActionOptions`
  gains `.background`. The host starts the app without a window if it has
  to, and delivers the response as usual.
- **A push with data only reaches a closed app.** It arrives in
  `received`. The manifest says so:
  `.notifications(remote: true, wakesApp: true)`.

What's built of these is the guest's side and the manifest's: the option
on an action, which reaches the host as bit 4 of its options, and
`wakesApp`, which the packager checks and puts in the bundle. Starting the
app for them is each platform host's work.

In both, the app has the time its handler takes to return, and no more.
To go on after that, such as to fetch what the push announced, it begins
an activity before it returns:

```swift
center.onReceive { notification in
    guard notification.isRemote else { return }
    let activity = scheduler.beginActivity("Fetch")
    mailbox.fetchNewMessages { _ in activity.end() }
}
```

A push is the way to be timely: a mail app's server pushes when mail
arrives, and the scheduled task is what catches up when a push was missed.

## The contracts

```swift
@DynamicRuntime("org.pureswift.background.Tasks", requires: .backgroundTasks)
protocol BackgroundTasks {
    static func shared() -> Self

    /// A `PermissionStatus`. Never prompts.
    func status() -> Int32

    /// Where runs are announced. Set before `rt_main` returns.
    func setDelegate(_ delegate: BackgroundTasksDelegate?)

    /// `kind`: 0 refresh, 1 processing. `earliest` and `interval` are
    /// seconds; `interval` 0 is once. `requirements`: bits, 1 network,
    /// 2 charging.
    func submit(_ identifier: String, kind: Int32, earliest: Double, interval: Double, requirements: Int32, callback: BackgroundCallback)   // didComplete
    func cancel(_ identifier: String)
    func cancelAll()
    func pending(_ callback: BackgroundCallback)                         // didList

    /// A run is over.
    func complete(_ run: Int32, success: Bool)

    /// Begins an activity. 0: the host can't keep the app running.
    func beginActivity(_ name: String) -> Int32
    func endActivity(_ activity: Int32)

    /// Seconds before the host stops the app; −1 where it isn't known or
    /// isn't limited.
    func timeRemaining() -> Double
}

@DynamicCallback("org.pureswift.background.TasksDelegate")
protocol BackgroundTasksDelegate {
    /// Do the task's work, then call `complete` with `run`.
    func run(_ identifier: String, run: Int32)
    /// Out of time: stop, and complete the run now.
    func didExpire(_ run: Int32)
    /// Out of time for an activity the app began. It has ended.
    func didExpireActivity(_ activity: Int32)
}

@DynamicCallback("org.pureswift.background.Callback")
protocol BackgroundCallback {
    func didComplete()
    func didList(_ identifiers: [String])
    func didFail(_ error: Int32)
}
```

Runs and activities are numbers, not objects, so no host has to read back
an object the guest made.

### Rules every host follows

- **One callback object per operation**, held until exactly one of its
  methods is called, on the main thread.
- **The app runs while a run or an activity is open.** The host doesn't
  stop it before each is completed, ended or expired.
- **A run is completed once.** After `didExpire` the host waits a moment
  for `complete` (two seconds, in the shared host), then counts the run as
  failed.
- **A run with no delegate fails.** If the app has set none by the time
  `rt_main` returns, the host completes the run as failed.
- **Never sooner.** A task doesn't run before `earliest`, or more often
  than `interval`. Later is always allowed.
- **A repeating request is asked again by the host** after each run,
  whether it succeeded or not.
- **Requests survive.** They're kept across launches and restarts of the
  device, until cancelled.
- **An identifier the manifest doesn't name** fails with `notDeclared`,
  and so does one it names as the other kind.
- **A host keeps at least one refresh and ten processing requests.** Past
  its limit, `limitReached`.
- **Run and activity numbers aren't reused** while the app runs.

### Errors

`BackgroundError`, from `didFail`:

| Value | Case |
|---|---|
| 0 | `unknown` |
| 1 | `cancelled`: guest-side only, a cancelled task |
| 2 | `notDeclared`: the manifest doesn't name the task |
| 3 | `notRegistered`: guest-side, no handler for the task |
| 4 | `unsupported`: this host runs nothing in the background |
| 5 | `invalid`: an interval under 900 seconds, or a time before now |
| 6 | `limitReached`: the host keeps no more requests |

A request made while the user has background activity off isn't an error:
it's kept.

## The manifest

```swift
let app = App(
    …
    capabilities: [.backgroundTasks, .notifications(remote: true, wakesApp: true)],
    backgroundTasks: [
        .refresh("org.example.mail.sync"),
        .processing("org.example.mail.index"),
    ]
)
```

`.backgroundTasks` has no usage text and prompts for nothing.

| | `.backgroundTasks` and its tasks | `wakesApp` on notifications |
|---|---|---|
| iOS | `BGTaskSchedulerPermittedIdentifiers`; `UIBackgroundModes` with `fetch` for a refresh task and `processing` for a processing task | `UIBackgroundModes: remote-notification` |
| Android | nothing: `WorkManager` needs no permission | nothing |
| Linux | the background service's socket, and the tasks registered with it at install | the push service starts the app |
| macOS | nothing | nothing |
| Browser | nothing | nothing |

The packager writes the tasks into the bundle's `Info.plist` as
`RTBackgroundTasks`, each with `Identifier` and `Kind`. A manifest with
tasks and no `.backgroundTasks` is a build error, and so is an identifier
named twice.

## For a host

A host written in Swift implements `BackgroundScheduler`, and
`HostBackgroundTasks` does the rest:

```swift
final class MyScheduler: BackgroundScheduler {
    var status: PermissionStatus { … }
    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) { … }
    func cancel(_ identifier: String?) { … }                 // nil: all
    func pending(_ completion: @escaping ([String]) -> Void) { … }
    // With defaults: repeatsRequests, beginActivity, endActivity, timeRemaining.
}

HostBackgroundTasks.scheduler = MyScheduler()
HostBackgroundTasks.declared = ["org.example.mail.sync": .refresh]     // RTBackgroundTasks
HostBackgroundTasks.requestsFile = hostData + "/background-requests"
HostBackgroundTasksModule.register(in: runtime)

// After rt_main has returned, when the system runs a task:
let run = HostBackgroundTasks.start("org.example.mail.sync") { success in
    systemTask.setTaskCompleted(success: success)
}
// When its time is up:
HostBackgroundTasks.expire(run)
// When an activity the guest began is out of time:
HostBackgroundTasks.expireActivity(number)
```

- **It checks each request** against `declared` and the 900-second floor
  before the scheduler sees it.
- **It numbers runs and activities,** and tells the system how each run
  went, once: failed at once if the guest registered nothing, and failed
  when the guest doesn't complete within `gracePeriod` of being told its
  time is up.
- **It asks again for a repeating request** as each run starts, for a
  scheduler whose platform runs a request once. It remembers them in
  `requestsFile`, since the app was started afresh for the run.
- **`isIdle` and `onIdle`** say when no run or activity is open: nothing
  holds the app, and the platform may stop it.
- **A scheduler that can't hold the app** leaves `beginActivity` at its
  default, and the guest gets an activity that has already expired.

Android and the browser aren't written in Swift, and implement the
contract themselves.

## Per host

| | Notes |
|---|---|
| iOS | The host registers a launch handler for each of the manifest's tasks before launch finishes, natively, and forwards each to the delegate. `BGAppRefreshTaskRequest` and `BGProcessingTaskRequest`, with `earliestBeginDate`; a repeating request is submitted again as its run starts. `expirationHandler` is `didExpire`. An activity is `beginBackgroundTask`, and `timeRemaining` is `backgroundTimeRemaining`. `status` is `backgroundRefreshStatus`. An app the user swiped away isn't started until they open it again. |
| Android | `PeriodicWorkRequest` (15 minutes at least) or `OneTimeWorkRequest` with a delay, and `Constraints` for the network, charging, and an idle device for processing. The `Worker` starts the guest in the process with no activity, and `onStopped` is `didExpire`. Nothing on Android holds a process for a moment's work, so an activity there is `0`: the app runs on only while the system leaves it. `status` is `isBackgroundRestricted`. |
| Linux | Below. |
| macOS | A Mac app isn't suspended, so activities are never needed and `timeRemaining` is −1. `NSBackgroundActivityScheduler` runs tasks while the app is open; nothing starts a closed app. |
| Browser | `status` is `unavailable`, `submit` fails with `unsupported`, and an activity is `0`. A browser's periodic sync runs in a service worker, where the guest isn't. |

### Linux

A sketch, for the Linux host's own design:

- **A background service** keeps each app's requests on disk and decides
  when to run them, from power, network and how much the app is used.
- **It starts the app as the launcher does,** in the same sandbox, display
  included, so that it can show its window later without being started
  again. A background start makes no window.
- **It ends a run that's out of time,** by telling the host and then by
  freezing the app's cgroup.
- **An activity** asks the service not to freeze the app yet.
- **The shell has the switch** per app, which is `status`.

## Capability

`.backgroundTasks`. It prompts for nothing: the system's setting is the
user's control, and `status` reads it.

## Threading

Every callback and delegate method runs on the main thread (§6.4). The
guest has one thread in the background too.

## Example and tests

`examples/ExampleBackground`: a feed that keeps itself fresh. It registers
a task whose handler awaits the host, asks for it to be run every quarter
of an hour, withdraws that, and asks for time to finish a save.

- `DynamicBackgroundTasksTests`: the contract's keys and signatures, and
  `BackgroundTaskScheduler` against a scripted host.
- `RuntimeBackgroundTasksTests`: `HostBackgroundTasks` over a scheduler
  the test keeps in memory, driven from the guest.
- The example runs against `HostBackgroundTasks` as `App.wasm` under
  WasmKit (`Packages/RuntimeWasm`), and as a sealed native slice and
  wasm2c output (`Packages/LinkedSlice`).

Everything is tested against a scheduler in memory, with the test standing
for the system. No system has started a guest in the background, and the
platforms' limits above are from their documentation.

## Not in this design

- **Work that goes on for a long time with the user's knowledge:** an
  export, a backup. Android has foreground services for it; iOS has much
  less. It's a contract of its own if an app needs it.
- **Transfers that outlive the app:** downloads and uploads the system
  carries on. That's an addition to [HTTPClient](HTTPClient.md).
- **Playing on, and following location,** in the background. Those are
  [MediaPlayer](MediaPlayer.md)'s and [Location](Location.md)'s.
- **Exact times.** A task can't be made to run at a moment.
- **A browser.**
- **Restoring an app's state** after the system stopped it.
- **Starting at login or at boot.**

## Decided in review

The design was approved as drafted, so these stand:

- **The same `rt_main` for a background start,** with the host's renderer
  waiting for a window.
- **One rule for the background:** the app runs while it holds a run or an
  activity.
- **Repeating requests** that the host asks again.
- **Names:** `DynamicBackgroundTasks`, `BackgroundTaskScheduler`, the
  capability `.backgroundTasks`, and `wakesApp` on notifications.
- **Tasks in the manifest,** on every platform.
- **The two additions to notifications** in this design.
- **No browser support.**
