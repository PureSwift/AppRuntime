#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// One barometer sample.
public struct AltitudeSample: Equatable, Sendable {

    /// Kilopascals.
    public var pressure: Double

    /// Meters since updates started.
    public var relativeAltitude: Double

    /// Host monotonic nanoseconds.
    public var timestamp: Int64

    public init(pressure: Double, relativeAltitude: Double, timestamp: Int64) {
        self.pressure = pressure
        self.relativeAltitude = relativeAltitude
        self.timestamp = timestamp
    }
}

/// Async/await over `Altimeter` (§6.2.1): the guest-side convenience layer.
///
/// `authorization` never prompts; `requestAuthorization()` is the only call
/// that does. One update stream at a time. The guest is single-threaded
/// (§6.4).
public final class AsyncAltimeter: @unchecked Sendable {

    /// The underlying contract object.
    public let altimeter: any Altimeter

    let events: AltimeterEvents

    public init() {
        let events = AltimeterEvents()
        self.events = events
        self.altimeter = AltimeterProxy.make(events)
    }

    /// Whether this host has a barometer, with the capability granted.
    public static var isAvailable: Bool {
        AltimeterProxy.isAvailable && AltimeterProxy.isAvailable()
    }

    /// The current authorization. Never prompts.
    public static var authorization: MotionAuthorization {
        MotionAuthorization(rawValue: AltimeterProxy.authorizationStatus()) ?? .notDetermined
    }

    /// Prompts for Motion & Fitness access if it hasn't been decided, and
    /// returns the outcome. Returns the current authorization if the task
    /// is cancelled.
    public func requestAuthorization() async -> MotionAuthorization {
        let current = Self.authorization
        guard current == .notDetermined else { return current }
        return await withCallback { (callback: Callback<MotionAuthorization, Never>) in
            events.authorization.append(callback)
            altimeter.requestAuthorization()
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
    }

    /// Samples until the stream is released or its task is cancelled.
    public func updates() -> EventStream<AltitudeSample, MotionError> {
        let (stream, continuation) = EventStream<AltitudeSample, MotionError>.makeStream()
        events.updates?.finish()
        events.generation &+= 1
        let generation = events.generation
        events.updates = continuation
        continuation.onTermination = { [events, altimeter] in
            guard events.generation == generation else { return }
            events.updates = nil
            altimeter.stopUpdates()
        }
        altimeter.startUpdates()
        return stream
    }
}

/// The delegate behind `AsyncAltimeter`.
final class AltimeterEvents: AltimeterDelegate {

    let authorization = PendingCallbacks<MotionAuthorization, Never>()

    var updates: EventStream<AltitudeSample, MotionError>.Continuation?

    var generation = 0

    func didChangeAuthorization(_ altimeter: any Altimeter, status: Int32) {
        let status = MotionAuthorization(rawValue: status) ?? .notDetermined
        guard status != .notDetermined else { return }
        authorization.resumeAll(with: .success(status))
        if status == .denied || status == .restricted {
            updates?.finish(throwing: .unauthorized)
        }
    }

    func didUpdate(_ altimeter: any Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64) {
        updates?.yield(AltitudeSample(pressure: pressure, relativeAltitude: relativeAltitude, timestamp: timestamp))
    }

    func didFail(_ altimeter: any Altimeter, error: Int32) {
        updates?.finish(throwing: MotionError(code: error) ?? .unknown)
    }
}
#endif
