import DynamicRuntime

/// Device location: authorization and position updates.
///
/// Implemented over CoreLocation (`CLLocationManager`), Android's
/// `LocationManager` / fused location provider, or GeoClue on Linux.
@DynamicRuntime("org.pureswift.location.LocationManager", requires: .location)
public protocol LocationManager: AnyObject {

    static func make(_ delegate: LocationManagerDelegate) -> Self

    /// A `LocationAuthorization` raw value.
    func authorizationStatus() -> Int32

    /// Asks for when-in-use access; the result arrives through
    /// `didChangeAuthorization`. Hosts that grant access at install time
    /// report the current status.
    func requestWhenInUseAuthorization()

    /// Desired accuracy in meters; `0` for the best available.
    func setDesiredAccuracy(_ meters: Double)

    /// Minimum distance in meters between updates; `0` for every change.
    func setDistanceFilter(_ meters: Double)

    func startUpdatingLocation()

    func stopUpdatingLocation()

    /// Delivers one location, then stops.
    func requestLocation()

    /// The most recent location, if any.
    func lastLocation() -> Location?
}
