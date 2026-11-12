import DynamicRuntime

/// Step counting, distance and floors.
///
/// Permissions first: iOS needs Motion & Fitness access
/// (`NSMotionUsageDescription`); Android 10+ needs the
/// `ACTIVITY_RECOGNITION` runtime permission.
///
/// | Host | Implementation | History |
/// |---|---|---|
/// | iOS | `CMPedometer` | last 7 days |
/// | Android | `TYPE_STEP_COUNTER` sensor | none: counts start at `startUpdates` |
@DynamicRuntime("org.pureswift.motion.Pedometer", requires: .motion)
public protocol Pedometer: AnyObject {

    static func isStepCountingAvailable() -> Bool

    /// Distance estimates (iOS only).
    static func isDistanceAvailable() -> Bool

    /// Floors climbed (iOS devices with a barometer).
    static func isFloorCountingAvailable() -> Bool

    /// Whether `query(from:to:)` can return past data.
    static func isHistoryAvailable() -> Bool

    /// A `MotionAuthorization` raw value. Never prompts.
    static func authorizationStatus() -> Int32

    /// Never prompts.
    static func make(_ delegate: PedometerDelegate) -> Self

    /// Shows the permission prompt if not determined; the result arrives
    /// through `didChangeAuthorization`.
    func requestAuthorization()

    /// Live updates of cumulative counts since `start` (milliseconds since
    /// 1970 UTC). Without history, counting starts now regardless of
    /// `start`.
    func startUpdates(from start: Int64)

    func stopUpdates()

    /// Counts between two dates (milliseconds since 1970 UTC), delivered
    /// through `didQuery`. Fails with `.historyUnavailable` without history.
    func query(from start: Int64, to end: Int64)
}
