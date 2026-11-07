import DynamicRuntime

/// Receives `Altimeter` events on the main thread.
@DynamicCallback("org.pureswift.motion.AltimeterDelegate")
public protocol AltimeterDelegate: AnyObject {

    /// `status` is a `MotionAuthorization` raw value.
    func didChangeAuthorization(_ altimeter: Altimeter, status: Int32)

    /// `pressure` in kilopascals; `relativeAltitude` in meters since
    /// `startUpdates()` (Android hosts compute it from pressure);
    /// `timestamp` in nanoseconds since boot.
    func didUpdate(_ altimeter: Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64)

    /// `error` is a `MotionError` raw value. Updates have stopped.
    func didFail(_ altimeter: Altimeter, error: Int32)
}
