import DynamicRuntime

/// Receives `Pedometer` events on the main thread. Counts that a host
/// can't provide are `-1` (`steps`, floors) or `nan` (`distance`); dates
/// are milliseconds since 1970 UTC.
@DynamicCallback("org.pureswift.motion.PedometerDelegate")
public protocol PedometerDelegate: AnyObject {

    /// `status` is a `MotionAuthorization` raw value.
    func didChangeAuthorization(_ pedometer: Pedometer, status: Int32)

    /// Cumulative counts since the start of updates.
    func didUpdate(_ pedometer: Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64)

    /// The result of `query(from:to:)`. `error` is a `MotionError` raw value,
    /// `0` on success.
    func didQuery(_ pedometer: Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32, start: Int64, end: Int64, error: Int32)

    /// `error` is a `MotionError` raw value. Live updates have stopped.
    func didFail(_ pedometer: Pedometer, error: Int32)
}
