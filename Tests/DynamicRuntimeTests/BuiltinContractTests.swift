import Testing
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeNative

// MARK: - Host fakes

final class HostPermissions: Permissions {

    nonisolated(unsafe) static var statuses: [Capability: PermissionStatus] = [:]

    /// Requests the user hasn't answered yet.
    nonisolated(unsafe) static var pending: [(capability: Capability, delegate: any PermissionsDelegate)] = []

    static func status(_ capability: Capability) -> Int32 {
        (statuses[capability] ?? .notDetermined).rawValue
    }

    static func request(_ capability: Capability, delegate: any PermissionsDelegate) {
        pending.append((capability, delegate))
    }
}

final class HostBundle: AppBundle {

    /// The tables the guest asked for.
    nonisolated(unsafe) static var tables: [String?] = []

    static func identifier() -> String { "org.example.App" }
    static func version() -> String { "1.2" }
    static func build() -> String { "42" }
    static func preferredLanguages() -> [String] { ["fr-CA", "en"] }

    static func localizedString(_ key: String, table: String?) -> String? {
        tables.append(table)
        return key == "hello" && table == nil ? "Bonjour" : nil
    }
}

final class HostApplication: Application {

    nonisolated(unsafe) static var current: HostApplication?

    var current: ApplicationState = .active

    let delegate: any ApplicationDelegate

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any ApplicationDelegate) -> HostApplication {
        let application = HostApplication(delegate: delegate)
        current = application
        return application
    }

    func state() -> Int32 { current.rawValue }
}

// MARK: - Guest delegates

final class PermissionResults: PermissionsDelegate {

    var results: [(Capability, PermissionStatus?)] = []

    func didRequest(_ capability: Capability, status: Int32) {
        results.append((capability, PermissionStatus(rawValue: status)))
    }
}

final class LifecycleRecorder: ApplicationDelegate {

    var events: [String] = []

    func didChangeState(_ application: any Application, state: Int32) {
        events.append("state \(state)")
    }

    func didReceiveMemoryWarning(_ application: any Application) {
        events.append("memory warning")
    }

    func open(_ application: any Application, url: String) -> Bool {
        events.append("open \(url)")
        return url.hasPrefix("example:")
    }
}

// MARK: - Tests

/// The `Permissions`, `Bundle` and `Application` built-ins (§7.4). Part of
/// `NativeModeTests`, which is serialized, since they use
/// `NativeRuntime.shared`.
extension NativeModeTests {

    @Test func builtinDescriptorsMatchTheContracts() {
        #expect(PermissionsProxy.descriptor == BuiltinContracts.permissions)
        #expect(PermissionsDelegateProxy.descriptor == BuiltinContracts.permissionsDelegate)
        #expect(AppBundleProxy.descriptor == BuiltinContracts.bundle)
        #expect(ApplicationProxy.descriptor == BuiltinContracts.application)
        #expect(ApplicationDelegateProxy.descriptor == BuiltinContracts.applicationDelegate)
    }

    @Test func builtinsWithoutAHostImplementationFail() {
        // Registered by every runtime, so they resolve; calls fail until the
        // host registers an implementation.
        let runtime = HostRuntime()
        let cls = runtime.lookupClass(Array(BuiltinContracts.bundleName.utf8), guest: nil)
        #expect(cls != 0)
        let method = runtime.lookupMethod(cls, key: Array("identifier".utf8), signature: Array("()O".utf8), flags: MethodKind.static.rawValue)
        #expect(method != 0)
        var results = [Slot](repeating: 0, count: 1)
        let status = results.withUnsafeMutableBufferPointer { results in
            runtime.call(target: 0, method: method, arguments: UnsafeBufferPointer(start: nil, count: 0), results: results)
        }
        #expect(status == .notFound)
    }

    @Test func permissions() throws {
        PermissionsProxy.register(HostPermissions.self, in: native)
        PermissionsDelegateProxy.registerInterface(in: native)
        HostPermissions.statuses = [.bluetooth: .granted]
        HostPermissions.pending = []
        let handles = native.runtime.handleCount
        let exports = Exported.liveCount

        #expect(try PermissionsProxy.status(.bluetooth) == PermissionStatus.granted.rawValue)
        #expect(try PermissionsProxy.status(.location) == PermissionStatus.notDetermined.rawValue)

        let delegate = PermissionResults()
        do {
            try PermissionsProxy.request(.location, delegate: delegate)
            let request = try #require(HostPermissions.pending.first)
            #expect(request.capability == .location)
            #expect(Exported.liveCount == exports + 1, "the host holds the delegate")
            // The user answers, and the host lets go of the delegate.
            HostPermissions.pending = []
            request.delegate.didRequest(.location, status: PermissionStatus.limited.rawValue)
        }
        #expect(delegate.results.map(\.0) == [.location])
        #expect(delegate.results.map(\.1) == [.limited])

        #expect(Exported.liveCount == exports)
        #expect(native.runtime.handleCount == handles)
    }

    @Test func bundle() throws {
        AppBundleProxy.register(HostBundle.self, in: native)
        HostBundle.tables = []
        let handles = native.runtime.handleCount

        #expect(try AppBundleProxy.identifier() == "org.example.App")
        #expect(try AppBundleProxy.version() == "1.2")
        #expect(try AppBundleProxy.build() == "42")
        #expect(try AppBundleProxy.preferredLanguages() == ["fr-CA", "en"])
        #expect(try AppBundleProxy.localizedString("hello", table: nil) == "Bonjour")
        #expect(try AppBundleProxy.localizedString("hello", table: "Errors") == nil)
        #expect(HostBundle.tables == [nil, "Errors"])

        #expect(native.runtime.handleCount == handles)
    }

    @Test func application() throws {
        ApplicationProxy.register(HostApplication.self, in: native)
        ApplicationDelegateProxy.registerInterface(in: native)
        let handles = native.runtime.handleCount
        let exports = Exported.liveCount

        let recorder = LifecycleRecorder()
        do {
            let application = try ApplicationProxy.make(recorder)
            #expect(try application.state() == ApplicationState.active.rawValue)
            let host = try #require(HostApplication.current)
            #expect(native.swiftObject(for: application) === host)

            host.current = .background
            host.delegate.didChangeState(host, state: ApplicationState.background.rawValue)
            #expect(try application.state() == ApplicationState.background.rawValue)
            host.delegate.didReceiveMemoryWarning(host)
            #expect(host.delegate.open(host, url: "example://item/1"))
            #expect(!host.delegate.open(host, url: "https://example.org"))
            HostApplication.current = nil
        }
        #expect(recorder.events == [
            "state 2",
            "memory warning",
            "open example://item/1",
            "open https://example.org",
        ])

        // Releasing the application releases the host's object and its
        // hold on the delegate.
        #expect(Exported.liveCount == exports)
        #expect(native.runtime.handleCount == handles)
    }
}
