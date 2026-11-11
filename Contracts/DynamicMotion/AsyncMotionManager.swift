#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// One accelerometer or gyroscope sample.
public struct MotionSample: Equatable, Sendable {

    /// Acceleration in m/s² (with gravity's sign as in `MotionManagerDelegate`),
    /// or rotation rate in radians per second.
    public var vector: Vector3

    /// Host monotonic nanoseconds.
    public var timestamp: Int64

    public init(vector: Vector3, timestamp: Int64) {
        self.vector = vector
        self.timestamp = timestamp
    }
}

/// One magnetometer sample.
public struct MagneticFieldSample: Equatable, Sendable {

    /// Microteslas.
    public var field: Vector3

    public var accuracy: MagneticFieldAccuracy

    public var timestamp: Int64

    public init(field: Vector3, accuracy: MagneticFieldAccuracy, timestamp: Int64) {
        self.field = field
        self.accuracy = accuracy
        self.timestamp = timestamp
    }
}

/// Async/await over `MotionManager` (§6.2.1): each sensor as an
/// `EventStream`. The guest-side convenience layer; native hosts never see
/// it. Sensors need no permission.
///
/// ```swift
/// let motion = AsyncMotionManager()
/// for try await sample in motion.acceleration(interval: 0.02) {
///     print(sample.vector.magnitude)
/// }
/// ```
///
/// A sensor runs while its stream is iterated, and stops when the stream is
/// released or its task is cancelled. One stream per sensor at a time:
/// starting one finishes the previous one for that sensor. The guest is
/// single-threaded (§6.4).
public final class AsyncMotionManager: @unchecked Sendable {

    /// The underlying contract object.
    public let manager: any MotionManager

    let updates: MotionUpdates

    private var acceleration: EventStream<MotionSample, MotionError>.Continuation?

    private var rotationRate: EventStream<MotionSample, MotionError>.Continuation?

    private var magneticField: EventStream<MagneticFieldSample, MotionError>.Continuation?

    private var deviceMotion: EventStream<DeviceMotion, MotionError>.Continuation?

    private var generations = [Int](repeating: 0, count: MotionSensor.allCases.count)

    public init() {
        let updates = MotionUpdates()
        self.updates = updates
        self.manager = MotionManagerProxy.make(updates)
        updates.onAcceleration = { [unowned(unsafe) self] vector, timestamp in
            self.acceleration?.yield(MotionSample(vector: vector, timestamp: timestamp))
        }
        updates.onRotationRate = { [unowned(unsafe) self] vector, timestamp in
            self.rotationRate?.yield(MotionSample(vector: vector, timestamp: timestamp))
        }
        updates.onMagneticField = { [unowned(unsafe) self] field, accuracy, timestamp in
            self.magneticField?.yield(MagneticFieldSample(field: field, accuracy: accuracy, timestamp: timestamp))
        }
        updates.onDeviceMotion = { [unowned(unsafe) self] motion in
            self.deviceMotion?.yield(motion)
        }
        updates.onFailure = { [unowned(unsafe) self] sensor, error in
            self.fail(sensor, error)
        }
    }

    deinit {
        // The closures don't keep this object alive; stop them reaching it.
        updates.onAcceleration = nil
        updates.onRotationRate = nil
        updates.onMagneticField = nil
        updates.onDeviceMotion = nil
        updates.onFailure = nil
    }

    public static func isAvailable(_ sensor: MotionSensor) -> Bool {
        MotionManagerProxy.isAvailable(sensor.rawValue)
    }

    /// The shortest interval the sensor supports, in seconds.
    public func minimumInterval(_ sensor: MotionSensor) -> Double {
        manager.minimumInterval(sensor.rawValue)
    }

    // MARK: Streams

    /// Accelerometer samples every `interval` seconds.
    public func acceleration(interval: Double, buffering: EventStream<MotionSample, MotionError>.Buffering = .unbounded) -> EventStream<MotionSample, MotionError> {
        let (stream, continuation) = EventStream<MotionSample, MotionError>.makeStream(buffering: buffering)
        acceleration?.finish()
        acceleration = continuation
        start(.accelerometer, interval: interval, continuation) { $0.acceleration = nil }
        return stream
    }

    /// Gyroscope samples every `interval` seconds.
    public func rotationRate(interval: Double, buffering: EventStream<MotionSample, MotionError>.Buffering = .unbounded) -> EventStream<MotionSample, MotionError> {
        let (stream, continuation) = EventStream<MotionSample, MotionError>.makeStream(buffering: buffering)
        rotationRate?.finish()
        rotationRate = continuation
        start(.gyroscope, interval: interval, continuation) { $0.rotationRate = nil }
        return stream
    }

    /// Magnetometer samples every `interval` seconds.
    public func magneticField(interval: Double, buffering: EventStream<MagneticFieldSample, MotionError>.Buffering = .unbounded) -> EventStream<MagneticFieldSample, MotionError> {
        let (stream, continuation) = EventStream<MagneticFieldSample, MotionError>.makeStream(buffering: buffering)
        magneticField?.finish()
        magneticField = continuation
        start(.magnetometer, interval: interval, continuation) { $0.magneticField = nil }
        return stream
    }

    /// Fused device motion every `interval` seconds.
    public func deviceMotion(interval: Double, buffering: EventStream<DeviceMotion, MotionError>.Buffering = .unbounded) -> EventStream<DeviceMotion, MotionError> {
        let (stream, continuation) = EventStream<DeviceMotion, MotionError>.makeStream(buffering: buffering)
        deviceMotion?.finish()
        deviceMotion = continuation
        start(.deviceMotion, interval: interval, continuation) { $0.deviceMotion = nil }
        return stream
    }

    private func start<Element>(
        _ sensor: MotionSensor,
        interval: Double,
        _ continuation: EventStream<Element, MotionError>.Continuation,
        clear: @escaping (AsyncMotionManager) -> Void
    ) {
        let index = Int(sensor.rawValue)
        generations[index] &+= 1
        let generation = generations[index]
        continuation.onTermination = { [self] in
            guard generations[index] == generation else { return }
            clear(self)
            manager.stop(sensor.rawValue)
        }
        manager.start(sensor.rawValue, interval: interval)
    }

    private func fail(_ sensor: MotionSensor?, _ error: MotionError) {
        switch sensor {
        case .accelerometer?:
            acceleration?.finish(throwing: error)
        case .gyroscope?:
            rotationRate?.finish(throwing: error)
        case .magnetometer?:
            magneticField?.finish(throwing: error)
        case .deviceMotion?:
            deviceMotion?.finish(throwing: error)
        case nil:
            acceleration?.finish(throwing: error)
            rotationRate?.finish(throwing: error)
            magneticField?.finish(throwing: error)
            deviceMotion?.finish(throwing: error)
        }
    }
}
#endif
