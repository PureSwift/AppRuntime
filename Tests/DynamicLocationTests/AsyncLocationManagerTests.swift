import Testing
@testable import DynamicLocation
import DynamicRuntime
import RuntimeNative

// MARK: - Host fakes

final class HostLocation: Location {
    let lat: Double
    init(_ latitude: Double) { self.lat = latitude }
    func latitude() -> Double { lat }
    func longitude() -> Double { -122 }
    func altitude() -> Double { 0 }
    func horizontalAccuracy() -> Double { 5 }
    func verticalAccuracy() -> Double { 5 }
    func speed() -> Double { 0 }
    func speedAccuracy() -> Double { -1 }
    func course() -> Double { -1 }
    func courseAccuracy() -> Double { -1 }
    func timestamp() -> Int64 { 0 }
    func isSimulated() -> Int32 { 0 }
}

final class HostHeading: Heading {
    func magneticHeading() -> Double { 90 }
    func trueHeading() -> Double { 92 }
    func headingAccuracy() -> Double { 1 }
    func timestamp() -> Int64 { 0 }
}

final class HostLocationManager: LocationManager {

    nonisolated(unsafe) static var status = LocationAuthorization.notDetermined.rawValue

    nonisolated(unsafe) static var last: HostLocationManager?

    let delegate: any LocationManagerDelegate

    var updating = false

    var headingUpdates = false

    /// The answer to requestLocation: a latitude, an error code, or nothing.
    var fix: Double? = 37

    var fixError: Int32 = 0

    var stopped = 0

    init(delegate: any LocationManagerDelegate) {
        self.delegate = delegate
    }

    static func authorizationStatus() -> Int32 { status }
    static func accuracyAuthorization() -> Int32 { LocationAccuracyAuthorization.full.rawValue }
    static func isLocationServicesEnabled() -> Bool { true }
    static func isHeadingAvailable() -> Bool { true }

    static func make(_ delegate: any LocationManagerDelegate) -> HostLocationManager {
        let manager = HostLocationManager(delegate: delegate)
        last = manager
        return manager
    }

    func requestWhenInUseAuthorization() {
        Self.status = LocationAuthorization.authorizedWhenInUse.rawValue
        delegate.didChangeAuthorization(self, status: Self.status, accuracy: 0)
    }

    func requestAlwaysAuthorization() {
        Self.status = LocationAuthorization.authorizedAlways.rawValue
        delegate.didChangeAuthorization(self, status: Self.status, accuracy: 0)
    }

    func requestFullAccuracy(_ purpose: String) { }
    func setDesiredAccuracy(_ accuracy: Int32) { }
    func setDistanceFilter(_ meters: Double) { }
    func setBackgroundUpdatesEnabled(_ enabled: Bool) { }

    func startUpdatingLocation() { updating = true }

    func stopUpdatingLocation() {
        updating = false
        stopped += 1
    }

    func requestLocation() {
        if fixError != 0 {
            delegate.didFail(self, error: fixError)
        } else if let fix {
            delegate.didUpdateLocations(self, locations: [HostLocation(fix)])
        }
    }

    func lastLocation() -> (any Location)? { nil }
    func startUpdatingHeading() { headingUpdates = true }
    func stopUpdatingHeading() { headingUpdates = false }

    func send(_ latitudes: [Double]) {
        delegate.didUpdateLocations(self, locations: latitudes.map { HostLocation($0) })
    }
}

// MARK: - Tests

/// `AsyncLocationManager` against a fake host, through the native runtime.
/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct AsyncLocationManagerTests {

    var native: NativeRuntime { NativeRuntime.shared }

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        LocationManagerProxy.register(HostLocationManager.self, in: native)
        LocationManagerDelegateProxy.registerInterface(in: native)
        LocationProxy.register(HostLocation.self, in: native)
        HeadingProxy.register(HostHeading.self, in: native)
        HostLocationManager.status = LocationAuthorization.notDetermined.rawValue
        HostLocationManager.last = nil
    }

    @Test func authorizationPromptsOnlyWhenUndecided() async {
        let manager = AsyncLocationManager()
        #expect(AsyncLocationManager.authorization == .notDetermined)
        #expect(await manager.requestWhenInUseAuthorization() == .authorizedWhenInUse)
        #expect(await manager.requestWhenInUseAuthorization().isAuthorized, "decided: no prompt")
        #expect(await manager.requestAlwaysAuthorization() == .authorizedAlways, "upgrades when in use")
    }

    @Test func currentLocation() async throws {
        let handles = native.runtime.handleCount
        do {
            let manager = AsyncLocationManager()
            let host = try #require(HostLocationManager.last)
            #expect(try await manager.currentLocation().latitude() == 37)

            host.fixError = LocationError.denied.rawValue
            await #expect(throws: LocationError.denied) {
                _ = try await manager.currentLocation()
            }
        }
        HostLocationManager.last = nil
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0)
    }

    @Test func cancellingCurrentLocationStopsIt() async throws {
        let manager = AsyncLocationManager()
        let host = try #require(HostLocationManager.last)
        host.fix = nil
        let request = Task { _ = try await manager.currentLocation() }
        while manager.events.currentLocation.isEmpty {
            await Task.yield()
        }
        request.cancel()
        await #expect(throws: LocationError.cancelled) {
            try await request.value
        }
        #expect(host.stopped == 1)
    }

    @Test func updatesIgnoreTransientFailures() async throws {
        let manager = AsyncLocationManager()
        let host = try #require(HostLocationManager.last)
        do {
            let updates = manager.locations()
            #expect(host.updating)
            host.send([1, 2])
            host.delegate.didFail(host, error: LocationError.locationUnknown.rawValue)
            host.send([3])
            host.delegate.didFail(host, error: LocationError.network.rawValue)
            var latitudes: [Double] = []
            await #expect(throws: LocationError.network) {
                for try await location in updates {
                    latitudes.append(location.latitude())
                }
            }
            #expect(latitudes == [1, 2, 3], "locationUnknown doesn't end the stream")
        }
        #expect(!host.updating)

        do {
            let headings = manager.headings()
            #expect(host.headingUpdates)
            host.delegate.didUpdateHeading(host, heading: HostHeading())
            var iterator = headings.makeAsyncIterator()
            #expect(try await iterator.next()?.trueHeading() == 92)
        }
        #expect(!host.headingUpdates, "releasing the stream stops headings")
    }
}
