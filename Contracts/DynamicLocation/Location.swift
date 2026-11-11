import DynamicRuntime

/// One position fix. Unavailable values are negative (accuracies, speed,
/// course) or `nan` (altitude). With approximate authorization the
/// coordinate is deliberately imprecise and `horizontalAccuracy` is large
/// (kilometers on iOS, about 2 km on Android).
@DynamicRuntime("org.pureswift.location.Location")
public protocol Location: AnyObject {

    /// Degrees, WGS 84.
    func latitude() -> Double

    /// Degrees, WGS 84.
    func longitude() -> Double

    /// Meters above mean sea level.
    func altitude() -> Double

    /// Radius of uncertainty in meters.
    func horizontalAccuracy() -> Double

    func verticalAccuracy() -> Double

    /// Meters per second.
    func speed() -> Double

    func speedAccuracy() -> Double

    /// Degrees clockwise from true north.
    func course() -> Double

    func courseAccuracy() -> Double

    /// Milliseconds since 1970-01-01 UTC.
    func timestamp() -> Int64

    /// `-1` unknown, `0` real, `1` simulated (a mock provider on Android,
    /// `isSimulatedBySoftware` on iOS 15+).
    func isSimulated() -> Int32
}
