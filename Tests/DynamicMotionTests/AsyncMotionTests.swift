import Testing
@testable import DynamicMotion
import DynamicRuntime
import RuntimeNative

// MARK: - Host fakes

final class HostMotionManager: MotionManager {

    nonisolated(unsafe) static var last: HostMotionManager?

    let delegate: any MotionManagerDelegate

    var active: Set<Int32> = []

    init(delegate: any MotionManagerDelegate) {
        self.delegate = delegate
    }

    static func isAvailable(_ sensor: Int32) -> Bool { true }

    static func make(_ delegate: any MotionManagerDelegate) -> HostMotionManager {
        let manager = HostMotionManager(delegate: delegate)
        last = manager
        return manager
    }

    func start(_ sensor: Int32, interval: Double) { active.insert(sensor) }
    func stop(_ sensor: Int32) { active.remove(sensor) }
    func isActive(_ sensor: Int32) -> Bool { active.contains(sensor) }
    func minimumInterval(_ sensor: Int32) -> Double { 0.01 }
}

final class HostPedometer: Pedometer {

    nonisolated(unsafe) static var status = MotionAuthorization.notDetermined.rawValue

    nonisolated(unsafe) static var last: HostPedometer?

    let delegate: any PedometerDelegate

    var updating = false

    var answerQueries = true

    var queries = 0

    init(delegate: any PedometerDelegate) {
        self.delegate = delegate
    }

    static func isStepCountingAvailable() -> Bool { true }
    static func isDistanceAvailable() -> Bool { true }
    static func isFloorCountingAvailable() -> Bool { false }
    static func isHistoryAvailable() -> Bool { true }
    static func authorizationStatus() -> Int32 { status }

    static func make(_ delegate: any PedometerDelegate) -> HostPedometer {
        let pedometer = HostPedometer(delegate: delegate)
        last = pedometer
        return pedometer
    }

    func requestAuthorization() {
        Self.status = MotionAuthorization.authorized.rawValue
        delegate.didChangeAuthorization(self, status: Self.status)
    }

    func startUpdates(from start: Int64) { updating = true }
    func stopUpdates() { updating = false }

    func query(from start: Int64, to end: Int64) {
        queries += 1
        guard answerQueries else { return }
        delegate.didQuery(self, steps: 1200, distance: 900, floorsAscended: -1, floorsDescended: -1, start: start, end: end, error: 0)
    }
}

// MARK: - Tests

/// The motion wrappers against fake hosts, through the native runtime.
/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct AsyncMotionTests {

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        MotionManagerProxy.register(HostMotionManager.self, in: native)
        MotionManagerDelegateProxy.registerInterface(in: native)
        PedometerProxy.register(HostPedometer.self, in: native)
        PedometerDelegateProxy.registerInterface(in: native)
        HostPedometer.status = MotionAuthorization.notDetermined.rawValue
        HostMotionManager.last = nil
        HostPedometer.last = nil
    }

    @Test func sensorStreamsStartAndStop() async throws {
        let motion = AsyncMotionManager()
        let host = try #require(HostMotionManager.last)
        do {
            let samples = motion.acceleration(interval: 0.02)
            #expect(host.active == [MotionSensor.accelerometer.rawValue])
            host.delegate.didUpdateAcceleration(host, x: 0, y: 0, z: -1, timestamp: 1)
            host.delegate.didUpdateAcceleration(host, x: 0, y: 3, z: 4, timestamp: 2)
            var magnitudes: [Double] = []
            for try await sample in samples {
                magnitudes.append(sample.vector.magnitude)
                if magnitudes.count == 2 { break }
            }
            #expect(magnitudes == [1, 5])
        }
        #expect(host.active.isEmpty, "releasing the stream stops the sensor")

        let rotation = motion.rotationRate(interval: 0.02)
        host.delegate.didFail(host, sensor: MotionSensor.gyroscope.rawValue, error: MotionError.unavailable.rawValue)
        await #expect(throws: MotionError.unavailable) {
            for try await _ in rotation { }
        }
        #expect(host.active.isEmpty)
    }

    @Test func pedometer() async throws {
        let pedometer = AsyncPedometer()
        let host = try #require(HostPedometer.last)
        #expect(await pedometer.requestAuthorization() == .authorized)

        let data = try await pedometer.query(from: 0, to: 60_000)
        #expect(data.steps == 1200)
        #expect(data.end == 60_000)

        host.answerQueries = false
        let query = Task { _ = try await pedometer.query(from: 0, to: 1) }
        while pedometer.events.queries.isEmpty {
            await Task.yield()
        }
        query.cancel()
        await #expect(throws: MotionError.cancelled) {
            try await query.value
        }

        do {
            let updates = pedometer.updates(from: 0)
            #expect(host.updating)
            host.delegate.didUpdate(host, steps: 10, distance: 7, floorsAscended: 0, floorsDescended: 0, start: 0, end: 1)
            var iterator = updates.makeAsyncIterator()
            #expect(try await iterator.next()?.steps == 10)
        }
        #expect(!host.updating)
    }
}
