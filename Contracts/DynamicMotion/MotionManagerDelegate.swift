import DynamicRuntime

/// Receives `MotionManager` samples on the main thread.
///
/// Samples are scalar arguments, not objects, so a 100 Hz stream costs one
/// dispatch per sample. `MotionUpdates` wraps them in Swift structs.
///
/// Conventions (hosts convert):
/// - Axes: x to the right, y toward the top, z out of the screen, relative
///   to the device's natural orientation (not the UI's current one).
/// - Acceleration and gravity in m/s², with Android's sign: a device lying
///   still, face up, reports z ≈ +9.81. iOS hosts multiply CoreMotion's
///   g values by −9.80665.
/// - Rotation rate in rad/s, counter-clockwise positive (right-hand rule).
/// - Magnetic field in µT.
/// - Attitude as a unit quaternion (x, y, z, w) rotating device coordinates
///   into a reference frame with z vertical and an arbitrary but fixed x
///   (CoreMotion `xArbitraryZVertical`, Android game rotation vector).
/// - `timestamp`: nanoseconds since boot, monotonic.
@DynamicCallback("org.pureswift.motion.MotionManagerDelegate")
public protocol MotionManagerDelegate: AnyObject {

    /// Raw acceleration, including gravity.
    func didUpdateAcceleration(_ manager: MotionManager, x: Double, y: Double, z: Double, timestamp: Int64)

    /// Bias-corrected rotation rate.
    func didUpdateRotationRate(_ manager: MotionManager, x: Double, y: Double, z: Double, timestamp: Int64)

    /// Calibrated magnetic field. `accuracy` is a `MagneticFieldAccuracy`
    /// raw value.
    func didUpdateMagneticField(_ manager: MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64)

    /// Fused device motion: attitude, gravity, user acceleration (gravity
    /// removed) and rotation rate, from one sample.
    func didUpdateDeviceMotion(
        _ manager: MotionManager,
        attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        userAccelerationX: Double, userAccelerationY: Double, userAccelerationZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double,
        timestamp: Int64
    )

    /// `sensor` is a `MotionSensor` and `error` a `MotionError` raw value.
    /// The sensor has stopped.
    func didFail(_ manager: MotionManager, sensor: Int32, error: Int32)
}
