import DynamicRuntime
import DynamicBackgroundTasks
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The example background app: a feed that keeps itself fresh. It registers
/// a task the system may run while the app is closed, asks for it to be
/// run from time to time, and holds the app a little longer to finish a
/// save.

/// The closures hold the feed, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Feed: @unchecked Sendable {

    /// How often the system has run the task.
    var refreshes: String = "Never refreshed"

    var schedule: String = "Not scheduled"

    /// What became of the save the app asked time for.
    var saving: String = ""

    var status: String = ""

    @ObservationIgnored var count: Int = 0

    @ObservationIgnored var activity: BackgroundActivity?

    @ObservationIgnored let scheduler = BackgroundTaskScheduler.shared

    static let task = "org.pureswift.example.background.refresh"

    /// At every launch, before `rt_main` returns: when the system starts
    /// the app to run the task, this is how it knows what the task does.
    func start() {
        #if !EMBEDDED_NO_CONCURRENCY
        scheduler.register(Self.task) {
            // Stands for fetching what's new: it waits on the host.
            let pending = try await self.scheduler.pendingIdentifiers()
            self.refreshed(scheduled: !pending.isEmpty)
        }
        #else
        scheduler.register(Self.task) { (task: BackgroundTask) in
            self.scheduler.pendingIdentifiers { result in
                switch result {
                case .success(let pending):
                    self.refreshed(scheduled: !pending.isEmpty)
                    task.complete(success: true)
                case .failure:
                    task.complete(success: false)
                }
            }
        }
        #endif
        switch scheduler.status {
        case .granted: status = "Background: on"
        case .denied, .restricted: status = "Background: off"
        default: status = "Background: none here"
        }
        showSchedule()
    }

    func refreshed(scheduled: Bool) {
        count += 1
        refreshes = "Refreshed \(count) times"
        schedule = scheduled ? "Scheduled" : "Not scheduled"
    }

    func showSchedule() {
        scheduler.pendingIdentifiers { result in
            if case .success(let pending) = result {
                self.schedule = pending.isEmpty ? "Not scheduled" : "Scheduled"
            }
        }
    }

    /// No sooner than every quarter of an hour; the system decides when.
    func keepFresh() {
        scheduler.submit(BackgroundTaskRequest(Self.task, every: BackgroundTaskRequest.shortestInterval)) { result in
            if case .failure(let error) = result {
                self.schedule = "Couldn't schedule: error \(error.rawValue)"
            } else {
                self.showSchedule()
            }
        }
    }

    func stop() {
        scheduler.cancel(Self.task)
        showSchedule()
    }

    /// Something to finish after the user leaves: the app asks for time.
    func saveLater() {
        let activity = scheduler.beginActivity("Saving")
        guard !activity.isExpired else {
            saving = "No time given"
            return
        }
        activity.onExpiration = {
            self.saving = "Ran out of time"
            self.activity = nil
        }
        self.activity = activity
        saving = "Saving…"
    }

    func saved() {
        guard let activity else { return }
        activity.end()
        self.activity = nil
        saving = "Saved"
    }
}

struct ContentView: View {

    let feed: Feed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feed.refreshes)
                .accessibilityIdentifier("refreshes")
            Text(feed.schedule)
                .accessibilityIdentifier("schedule")
            HStack(spacing: 8) {
                Button("Keep Fresh") { feed.keepFresh() }
                Button("Stop") { feed.stop() }
            }
            HStack(spacing: 8) {
                Button("Save Later") { feed.saveLater() }
                Button("Saved") { feed.saved() }
            }
            Text(feed.saving)
                .accessibilityIdentifier("saving")
            Text(feed.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleBackgroundApp: App {

    let feed = Feed()

    init() {
        feed.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(feed: feed)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice:
/// when the user opens the app, and when the system starts it to run a
/// task, with no window.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleBackgroundMain() -> rt_status {
    Runtime.main { ExampleBackgroundApp.run() }
}
