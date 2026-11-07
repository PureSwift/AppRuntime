import DynamicRuntime

/// A compass reading. On Android the host derives it from the rotation
/// vector sensor; it isn't available on Linux.
@DynamicRuntime("org.pureswift.location.Heading")
public protocol Heading: AnyObject {

    /// Degrees clockwise from magnetic north, 0–360.
    func magneticHeading() -> Double

    /// Degrees clockwise from true north; negative until a location is
    /// known (true north needs the magnetic declination).
    func trueHeading() -> Double

    /// Maximum deviation in degrees; negative if invalid (needs calibration).
    func headingAccuracy() -> Double

    /// Milliseconds since 1970-01-01 UTC.
    func timestamp() -> Int64
}
