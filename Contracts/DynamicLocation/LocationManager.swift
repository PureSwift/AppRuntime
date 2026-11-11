import DynamicRuntime

/// Device location and compass heading.
///
/// Permissions first: check `authorizationStatus()` (never prompts), create
/// the manager (never prompts), then call `requestWhenInUseAuthorization()`
/// from a user action. `requestAlwaysAuthorization()` is a second step,
/// valid only once when-in-use access is granted. Without authorization,
/// updates fail with `LocationError.denied`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `CLLocationManager` |
/// | Android | fused location provider (Google Play services), else `LocationManager` |
/// | Linux | GeoClue 2 |
@DynamicRuntime("org.pureswift.location.LocationManager", requires: .location)
public protocol LocationManager: AnyObject {

    /// A `LocationAuthorization` raw value. Never prompts.
    static func authorizationStatus() -> Int32

    /// A `LocationAccuracyAuthorization` raw value: whether the user granted
    /// precise or only approximate location.
    static func accuracyAuthorization() -> Int32

    /// Whether location services are on system-wide. When off, requests
    /// fail with `LocationError.servicesDisabled` and no prompt appears.
    static func isLocationServicesEnabled() -> Bool

    /// Whether the device can report a compass heading.
    static func isHeadingAvailable() -> Bool

    /// Never prompts.
    static func make(_ delegate: LocationManagerDelegate) -> Self

    /// Asks for foreground access (iOS when-in-use; Android
    /// `ACCESS_FINE_LOCATION` with `ACCESS_COARSE_LOCATION`, where the user
    /// may choose approximate). The result arrives through
    /// `didChangeAuthorization`.
    func requestWhenInUseAuthorization()

    /// Asks for background access, after when-in-use is granted. iOS may
    /// defer the prompt; Android 11+ can't prompt and opens the app's
    /// location settings instead. Needs the manifest's background location
    /// declaration; otherwise reports `LocationError.denied`.
    func requestAlwaysAuthorization()

    /// Asks for precise location once when only approximate is granted.
    /// `purpose` names the manifest's usage string for the prompt (iOS
    /// `NSLocationTemporaryUsageDescriptionDictionary` key); Android asks
    /// for `ACCESS_FINE_LOCATION`.
    func requestFullAccuracy(_ purpose: String)

    /// A `LocationAccuracy` raw value. Hosts map it to their own tiers.
    func setDesiredAccuracy(_ accuracy: Int32)

    /// Minimum distance in meters between updates; `0` for every change.
    func setDistanceFilter(_ meters: Double)

    /// Continue updates while the app is in the background. Needs
    /// `authorizedAlways` and the manifest's background declaration; Android
    /// hosts run a foreground service with a notification.
    func setBackgroundUpdatesEnabled(_ enabled: Bool)

    func startUpdatingLocation()

    func stopUpdatingLocation()

    /// Delivers one location, then stops.
    func requestLocation()

    /// The most recent location the host knows, if any. May be stale; check
    /// its timestamp.
    func lastLocation() -> Location?

    func startUpdatingHeading()

    func stopUpdatingHeading()
}
