import DynamicRuntime

/// Receives `LocationManager` events on the main thread.
@DynamicCallback("org.pureswift.location.LocationManagerDelegate")
public protocol LocationManagerDelegate: AnyObject {

    /// `status` is a `LocationAuthorization` raw value.
    func didChangeAuthorization(_ manager: LocationManager, status: Int32)

    /// Locations in chronological order.
    func didUpdateLocations(_ manager: LocationManager, locations: [Location])

    /// `error` is a `LocationError` raw value.
    func didFail(_ manager: LocationManager, error: Int32)
}
