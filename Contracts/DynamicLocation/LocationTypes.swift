/// Guest-side names for the integer codes the Location contracts carry.

/// `LocationManager.authorizationStatus()`.
public enum LocationAuthorization: Int32, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorizedAlways = 3
    case authorizedWhenInUse = 4
}

/// `LocationManagerDelegate.didFail` codes.
public enum LocationError: Int32, Error, Sendable {
    case unknown = 1
    case denied = 2
    case locationUnavailable = 3
    case network = 4
    case timeout = 5
}
