import DynamicRuntime

/// One position fix. Values that aren't available are negative (accuracies,
/// speed, course) or `nan` (altitude).
@DynamicRuntime("org.pureswift.location.Location")
public protocol Location: AnyObject {

    /// Degrees, WGS 84.
    func latitude() -> Double

    /// Degrees, WGS 84.
    func longitude() -> Double

    /// Meters above sea level.
    func altitude() -> Double

    /// Radius of uncertainty in meters.
    func horizontalAccuracy() -> Double

    func verticalAccuracy() -> Double

    /// Meters per second.
    func speed() -> Double

    /// Degrees relative to true north.
    func course() -> Double

    /// Milliseconds since 1970-01-01 UTC.
    func timestamp() -> Int64
}
