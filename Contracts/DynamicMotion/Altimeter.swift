import DynamicRuntime

/// Barometric pressure and relative altitude.
///
/// Permissions first: on iOS the altimeter needs Motion & Fitness access
/// (`NSMotionUsageDescription`), like the pedometer. Android's pressure
/// sensor needs none and reports `.authorized`.
@DynamicRuntime("org.pureswift.motion.Altimeter", requires: "motion")
public protocol Altimeter: AnyObject {

    static func isAvailable() -> Bool

    /// A `MotionAuthorization` raw value. Never prompts.
    static func authorizationStatus() -> Int32

    /// Never prompts.
    static func make(_ delegate: AltimeterDelegate) -> Self

    /// Shows the Motion & Fitness prompt if not determined; the result
    /// arrives through `didChangeAuthorization`.
    func requestAuthorization()

    func startUpdates()

    func stopUpdates()
}
