import DynamicRuntime

/// Inertial sensors: accelerometer, gyroscope, magnetometer, and fused
/// device motion (attitude, gravity, user acceleration).
///
/// No permission is needed on any host, so this contract has no
/// capability. Samples are delivered in one convention everywhere (see
/// `MotionManagerDelegate`): SI units, Android's sign convention, axes
/// relative to the device's natural orientation, monotonic nanosecond
/// timestamps.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / watchOS | `CMMotionManager` |
/// | Android | `SensorManager` (`TYPE_ACCELEROMETER`, `TYPE_GYROSCOPE`, `TYPE_MAGNETIC_FIELD`, `TYPE_GAME_ROTATION_VECTOR`, `TYPE_GRAVITY`, `TYPE_LINEAR_ACCELERATION`) |
/// | Linux | iio-sensor-proxy, where present |
@DynamicRuntime("org.pureswift.motion.MotionManager")
public protocol MotionManager: AnyObject {

    /// Whether `sensor` (a `MotionSensor` raw value) exists on this device.
    static func isAvailable(_ sensor: Int32) -> Bool

    static func make(_ delegate: MotionManagerDelegate) -> Self

    /// Starts delivering `sensor` samples about every `interval` seconds.
    /// The host clamps the interval to what it supports: about 100 Hz on
    /// iOS, 200 Hz on Android 12+ without `HIGH_SAMPLING_RATE_SENSORS`.
    func start(_ sensor: Int32, interval: Double)

    func stop(_ sensor: Int32)

    func isActive(_ sensor: Int32) -> Bool

    /// The shortest interval in seconds the host delivers for `sensor`.
    func minimumInterval(_ sensor: Int32) -> Double
}
