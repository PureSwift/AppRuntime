import DynamicRuntime

/// Receives `LocationManager` events on the main thread.
@DynamicCallback("org.pureswift.location.LocationManagerDelegate")
public protocol LocationManagerDelegate: AnyObject {

    /// `status` is a `LocationAuthorization` raw value and `accuracy` a
    /// `LocationAccuracyAuthorization` raw value. Also sent once after
    /// `make` with the current values.
    func didChangeAuthorization(_ manager: LocationManager, status: Int32, accuracy: Int32)

    /// Locations in chronological order.
    func didUpdateLocations(_ manager: LocationManager, locations: [Location])

    func didUpdateHeading(_ manager: LocationManager, heading: Heading)

    /// `error` is a `LocationError` raw value. Updates continue after
    /// `.locationUnknown`; any other error stops them.
    func didFail(_ manager: LocationManager, error: Int32)
}
