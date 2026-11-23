import DynamicRuntime
import RuntimeABI
import RuntimeHost
import Testing

/// `HostPermissions` and `HostApplication`, which keep their state in
/// statics, so the tests run one at a time.
@Suite(.serialized) struct BuiltinTests {

    final class Recorder: PermissionsDelegate, ApplicationDelegate {

        var results: [(Capability, Int32)] = []

        var states: [Int32] = []

        var urls: [String] = []

        var warnings = 0

        var handles = true

        func didRequest(_ capability: Capability, status: Int32) {
            results.append((capability, status))
        }

        func didChangeState(_ application: any Application, state: Int32) {
            states.append(state)
        }

        func didReceiveMemoryWarning(_ application: any Application) {
            warnings += 1
        }

        func open(_ application: any Application, url: String) -> Bool {
            urls.append(url)
            return handles
        }
    }

    /// Answers requests later, as a prompt would.
    final class Prompt: PermissionProvider {

        var current = PermissionStatus.notDetermined

        var pending: [(PermissionStatus) -> Void] = []

        func status() -> PermissionStatus {
            current
        }

        func request(_ completion: @escaping (PermissionStatus) -> Void) {
            pending.append(completion)
        }

        func answer(_ status: PermissionStatus) {
            current = status
            pending.forEach { $0(status) }
            pending = []
        }
    }

    @Test func routesPermissionsToProviders() {
        let prompt = Prompt()
        HostPermissions.declared = [.location, .nfc]
        HostPermissions.providers = [.location: prompt, .bluetooth: GrantedPermission()]
        defer {
            HostPermissions.declared = []
            HostPermissions.providers = [:]
        }

        #expect(HostPermissions.status(.location) == PermissionStatus.notDetermined.rawValue)
        // Undeclared, even though a module covers it.
        #expect(HostPermissions.status(.bluetooth) == PermissionStatus.denied.rawValue)
        // Declared, but no module covers it.
        #expect(HostPermissions.status(.nfc) == PermissionStatus.unavailable.rawValue)

        let recorder = Recorder()
        HostPermissions.request(.bluetooth, delegate: recorder)
        HostPermissions.request(.location, delegate: recorder)
        #expect(recorder.results.map(\.1) == [PermissionStatus.denied.rawValue])
        prompt.answer(.granted)
        #expect(recorder.results.map(\.0) == [.bluetooth, .location])
        #expect(recorder.results.map(\.1) == [PermissionStatus.denied.rawValue, PermissionStatus.granted.rawValue])
        #expect(HostPermissions.status(.location) == PermissionStatus.granted.rawValue)
    }

    @Test func reportsLifecycleToEveryApplication() {
        HostApplication.reset()
        defer { HostApplication.reset() }
        let first = Recorder()
        let second = Recorder()
        second.handles = false
        let applications = [HostApplication.make(first), HostApplication.make(second)]
        #expect(applications[0].state() == ApplicationState.active.rawValue)

        HostApplication.setState(.background)
        HostApplication.setState(.background)
        HostApplication.didReceiveMemoryWarning()
        #expect(HostApplication.open("weather://today"))
        #expect(first.states == [ApplicationState.background.rawValue])
        #expect(second.states == [ApplicationState.background.rawValue])
        #expect(first.warnings == 1 && second.warnings == 1)
        #expect(first.urls == ["weather://today"] && second.urls == ["weather://today"])
        #expect(applications[1].state() == ApplicationState.background.rawValue)
    }

    /// Implements only what `Application` had first, and gets the defaults.
    final class Plain: Application {
        static func make(_ delegate: any ApplicationDelegate) -> Plain { Plain() }
        func state() -> Int32 { 0 }
    }

    @Test func theDefaultsOpenNothing() throws {
        let plain = Plain()
        #expect(try !plain.openURL("https://swift.org"))
        try plain.setIdleTimerDisabled(true)
        let keys = BuiltinContracts.application.methods.map(\.key)
        #expect(keys.contains("openURL:") && keys.contains("setIdleTimerDisabled:"))
        #expect(BuiltinContracts.application.version == 1)
    }

    @Test func opensURLsThroughThePlatform() {
        HostApplication.reset()
        defer { HostApplication.reset() }
        let application = HostApplication.make(Recorder())
        #expect(!application.openURL("https://swift.org"), "no platform hook: nothing opens")

        var asked: [String] = []
        HostApplication.openURL = { url in
            asked.append(url)
            return !url.hasPrefix("nope:")
        }
        #expect(application.openURL("https://swift.org"))
        #expect(!application.openURL("nope:x"))
        #expect(!application.openURL("file:///etc/passwd"))
        #expect(!application.openURL("FILE:relative"))
        #expect(application.openURL("profile:me"), "a scheme that only ends in file")
        #expect(asked == ["https://swift.org", "nope:x", "profile:me"], "a file isn't the platform's to open")
    }

    @Test func keepsTheScreenAwakeWhileAnyApplicationAsks() {
        HostApplication.reset()
        defer { HostApplication.reset() }
        var changes: [Bool] = []
        HostApplication.idleTimerDisabledChanged = { changes.append($0) }
        let first = HostApplication.make(Recorder())
        var second: HostApplication? = HostApplication.make(Recorder())

        first.setIdleTimerDisabled(true)
        second?.setIdleTimerDisabled(true)
        first.setIdleTimerDisabled(false)
        #expect(changes == [true], "the second still asks")
        #expect(HostApplication.isIdleTimerDisabled)

        // In the background the screen may sleep; back in front it's kept
        // awake again.
        HostApplication.setState(.background)
        HostApplication.setState(.inactive)
        #expect(changes == [true, false, true])

        // Released while it asked.
        second = nil
        #expect(changes == [true, false, true, false])
        #expect(!HostApplication.isIdleTimerDisabled)
    }

    @Test func forgetsReleasedApplications() {
        HostApplication.reset()
        defer { HostApplication.reset() }
        let recorder = Recorder()
        var application: HostApplication? = HostApplication.make(recorder)
        #expect(application != nil)
        application = nil
        #expect(!HostApplication.open("weather://today"))
        #expect(recorder.urls.isEmpty)
    }
}
