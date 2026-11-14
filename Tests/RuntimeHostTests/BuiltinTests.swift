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
