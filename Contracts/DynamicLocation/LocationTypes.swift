/// Guest-side names for the integer codes the Location contracts carry.

/// `LocationManager.authorizationStatus()`.
public enum LocationAuthorization: Int32, Sendable {
    case notDetermined = 0
    /// Parental controls or device management prevent access.
    case restricted = 1
    /// The user refused, or turned access off. Only Settings can change it.
    case denied = 2
    /// Foreground and background (iOS Always; Android
    /// `ACCESS_BACKGROUND_LOCATION`).
    case authorizedAlways = 3
    /// Foreground only.
    case authorizedWhenInUse = 4
}

/// `LocationManager.accuracyAuthorization()`.
public enum LocationAccuracyAuthorization: Int32, Sendable {
    /// Precise location (iOS full accuracy; Android fine location).
    case full = 0
    /// Approximate only (iOS reduced accuracy; Android coarse location).
    case reduced = 1
}

/// `LocationManager.setDesiredAccuracy(_:)`.
///
/// | Tier | iOS | Android priority |
/// |---|---|---|
/// | `best` | `kCLLocationAccuracyBest` | `PRIORITY_HIGH_ACCURACY` |
/// | `nearestTenMeters` | `kCLLocationAccuracyNearestTenMeters` | `PRIORITY_HIGH_ACCURACY` |
/// | `hundredMeters` | `kCLLocationAccuracyHundredMeters` | `PRIORITY_BALANCED_POWER_ACCURACY` |
/// | `kilometer` | `kCLLocationAccuracyKilometer` | `PRIORITY_LOW_POWER` |
/// | `reduced` | `kCLLocationAccuracyReduced` | `PRIORITY_PASSIVE` with coarse |
public enum LocationAccuracy: Int32, Sendable {
    case best = 0
    case nearestTenMeters = 1
    case hundredMeters = 2
    case kilometer = 3
    case reduced = 4
}

/// `LocationManagerDelegate.didFail` codes.
public enum LocationError: Int32, Error, Sendable {
    case unknown = 1
    /// Authorization is missing or was revoked.
    case denied = 2
    /// Location services are off system-wide.
    case servicesDisabled = 3
    /// No fix yet; updates continue.
    case locationUnknown = 4
    case network = 5
    /// Heading needs calibration or isn't available.
    case headingFailure = 6
    /// The request needs background authorization or a manifest
    /// declaration the app lacks.
    case backgroundNotAllowed = 7
    /// The waiting task was cancelled. The async wrappers throw it; hosts
    /// never send it.
    case cancelled = 8
}

public extension LocationError {

    /// The error for a delegate `error` code: `nil` for `0`, success; codes
    /// this version doesn't know are `unknown`.
    init?(code: Int32) {
        guard code != 0 else { return nil }
        self = LocationError(rawValue: code) ?? .unknown
    }
}
