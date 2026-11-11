#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Step counts and distance over an interval.
public struct PedometerData: Equatable, Sendable {

    public var steps: Int64

    /// Meters; `nan` if the host can't measure distance.
    public var distance: Double

    /// `-1` if the host can't count floors.
    public var floorsAscended: Int32

    public var floorsDescended: Int32

    /// Host wall-clock milliseconds.
    public var start: Int64

    public var end: Int64

    public init(steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64) {
        self.steps = steps
        self.distance = distance
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.start = start
        self.end = end
    }
}

/// Async/await over `Pedometer` (§6.2.1): the guest-side convenience layer.
///
/// `authorization` never prompts; `requestAuthorization()` is the only call
/// that does. One update stream at a time. The guest is single-threaded
/// (§6.4).
public final class AsyncPedometer: @unchecked Sendable {

    /// The underlying contract object.
    public let pedometer: any Pedometer

    let events: PedometerEvents

    public init() {
        let events = PedometerEvents()
        self.events = events
        self.pedometer = PedometerProxy.make(events)
    }

    /// Whether this host provides a pedometer, with the capability granted.
    public static var isAvailable: Bool {
        PedometerProxy.isAvailable && PedometerProxy.isStepCountingAvailable()
    }

    public static var isDistanceAvailable: Bool {
        PedometerProxy.isDistanceAvailable()
    }

    public static var isFloorCountingAvailable: Bool {
        PedometerProxy.isFloorCountingAvailable()
    }

    public static var isHistoryAvailable: Bool {
        PedometerProxy.isHistoryAvailable()
    }

    /// The current authorization. Never prompts.
    public static var authorization: MotionAuthorization {
        MotionAuthorization(rawValue: PedometerProxy.authorizationStatus()) ?? .notDetermined
    }

    /// Prompts for Motion & Fitness access if it hasn't been decided, and
    /// returns the outcome. Returns the current authorization if the task
    /// is cancelled.
    public func requestAuthorization() async -> MotionAuthorization {
        let current = Self.authorization
        guard current == .notDetermined else { return current }
        return await withCallback { (callback: Callback<MotionAuthorization, Never>) in
            events.authorization.append(callback)
            pedometer.requestAuthorization()
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
    }

    /// Cumulative counts since `start` (host wall-clock milliseconds), each
    /// time they change, until the stream is released or its task is
    /// cancelled.
    public func updates(from start: Int64) -> EventStream<PedometerData, MotionError> {
        let (stream, continuation) = EventStream<PedometerData, MotionError>.makeStream()
        events.updates?.finish()
        events.generation &+= 1
        let generation = events.generation
        events.updates = continuation
        continuation.onTermination = { [events, pedometer] in
            guard events.generation == generation else { return }
            events.updates = nil
            pedometer.stopUpdates()
        }
        pedometer.startUpdates(from: start)
        return stream
    }

    /// Counts for a past interval, from the host's history.
    public func query(from start: Int64, to end: Int64) async throws(MotionError) -> PedometerData {
        try await withCallback { (callback: Callback<PedometerData, MotionError>) in
            events.queries.append(callback)
            pedometer.query(from: start, to: end)
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
}

/// The delegate behind `AsyncPedometer`.
final class PedometerEvents: PedometerDelegate {

    let authorization = PendingCallbacks<MotionAuthorization, Never>()

    var updates: EventStream<PedometerData, MotionError>.Continuation?

    var generation = 0

    let queries = PendingCallbacks<PedometerData, MotionError>()

    func didChangeAuthorization(_ pedometer: any Pedometer, status: Int32) {
        let status = MotionAuthorization(rawValue: status) ?? .notDetermined
        guard status != .notDetermined else { return }
        authorization.resumeAll(with: .success(status))
        if status == .denied || status == .restricted {
            updates?.finish(throwing: .unauthorized)
        }
    }

    func didUpdate(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64) {
        updates?.yield(PedometerData(steps: steps, distance: distance, floorsAscended: floorsAscended, floorsDescended: floorsDescended, start: start, end: end))
    }

    func didQuery(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64, error: Int32) {
        if let error = MotionError(code: error) {
            queries.resume(with: .failure(error))
        } else {
            queries.resume(with: .success(PedometerData(steps: steps, distance: distance, floorsAscended: floorsAscended, floorsDescended: floorsDescended, start: start, end: end)))
        }
    }

    func didFail(_ pedometer: any Pedometer, error: Int32) {
        updates?.finish(throwing: MotionError(code: error) ?? .unknown)
    }
}
#endif
