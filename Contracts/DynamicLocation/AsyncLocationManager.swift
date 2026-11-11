#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Async/await over `LocationManager` (§6.2.1): the guest-side convenience
/// layer. Native hosts never see it.
///
/// Permissions come first: `authorization` never prompts, and the
/// `request…Authorization()` calls are the only ones that do.
///
/// ```swift
/// let location = AsyncLocationManager()
/// guard await location.requestWhenInUseAuthorization().isAuthorized else { return }
/// let here = try await location.currentLocation()
/// for try await update in location.locations() {
///     print(update.latitude(), update.longitude())
/// }
/// ```
///
/// One location stream and one heading stream at a time: starting one
/// finishes the previous one. The guest is single-threaded (§6.4).
public final class AsyncLocationManager: @unchecked Sendable {

    /// The underlying contract object, for settings without an async form
    /// (`setDesiredAccuracy`, `setDistanceFilter`, …).
    public let manager: any LocationManager

    let events: LocationEvents

    /// Makes a manager. Doesn't prompt for permission.
    public init() {
        let events = LocationEvents()
        self.events = events
        self.manager = LocationManagerProxy.make(events)
    }

    /// Whether this host provides location, with the capability granted.
    public static var isAvailable: Bool {
        LocationManagerProxy.isAvailable
    }

    // MARK: Authorization

    /// The current authorization. Never prompts.
    public static var authorization: LocationAuthorization {
        LocationAuthorization(rawValue: LocationManagerProxy.authorizationStatus()) ?? .notDetermined
    }

    public static var accuracyAuthorization: LocationAccuracyAuthorization {
        LocationAccuracyAuthorization(rawValue: LocationManagerProxy.accuracyAuthorization()) ?? .reduced
    }

    public static var isLocationServicesEnabled: Bool {
        LocationManagerProxy.isLocationServicesEnabled()
    }

    /// Prompts for when-in-use permission if it hasn't been decided, and
    /// returns the outcome. Returns the current authorization if the task
    /// is cancelled.
    public func requestWhenInUseAuthorization() async -> LocationAuthorization {
        await requestAuthorization { manager.requestWhenInUseAuthorization() }
    }

    /// Prompts for always permission, and returns the outcome. A host may
    /// answer without prompting, or defer the prompt (see the contract's
    /// permission table).
    public func requestAlwaysAuthorization() async -> LocationAuthorization {
        await requestAuthorization(alwaysAsks: true) { manager.requestAlwaysAuthorization() }
    }

    /// Asks for temporary full accuracy, and returns the accuracy
    /// authorization afterwards.
    ///
    /// - Parameter purpose: The key of the purpose string in the manifest.
    public func requestFullAccuracy(_ purpose: String) async -> LocationAccuracyAuthorization {
        guard Self.accuracyAuthorization != .full else { return .full }
        _ = await withCallback { (callback: Callback<LocationAuthorization, Never>) in
            events.authorization.append(callback)
            manager.requestFullAccuracy(purpose)
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
        return Self.accuracyAuthorization
    }

    private func requestAuthorization(alwaysAsks: Bool = false, _ request: () -> Void) async -> LocationAuthorization {
        let current = Self.authorization
        guard current == .notDetermined || (alwaysAsks && current == .authorizedWhenInUse) else {
            return current
        }
        return await withCallback { (callback: Callback<LocationAuthorization, Never>) in
            events.authorization.append(callback)
            request()
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
    }

    // MARK: Location

    /// One location fix. Throws the host's error, `denied` if permission is
    /// missing, or `cancelled` if the task is cancelled.
    public func currentLocation() async throws(LocationError) -> any Location {
        try await withCallback { (callback: Callback<any Location, LocationError>) in
            events.currentLocation.append(callback)
            manager.requestLocation()
        } onCancel: { [events, manager] callback in
            callback.resume(throwing: .cancelled)
            if events.locations == nil {
                manager.stopUpdatingLocation()
            }
        }
    }

    /// Location updates until the stream is released or its task is
    /// cancelled, which stops them. `locationUnknown` failures don't end
    /// the stream (the host keeps trying); other failures do.
    public func locations() -> EventStream<any Location, LocationError> {
        let (stream, continuation) = EventStream<any Location, LocationError>.makeStream()
        events.locations?.finish()
        events.locationGeneration &+= 1
        let generation = events.locationGeneration
        events.locations = continuation
        continuation.onTermination = { [events, manager] in
            guard events.locationGeneration == generation else { return }
            events.locations = nil
            manager.stopUpdatingLocation()
        }
        manager.startUpdatingLocation()
        return stream
    }

    // MARK: Heading

    public static var isHeadingAvailable: Bool {
        LocationManagerProxy.isHeadingAvailable()
    }

    /// Compass headings until the stream is released or its task is
    /// cancelled, which stops them.
    public func headings() -> EventStream<any Heading, LocationError> {
        let (stream, continuation) = EventStream<any Heading, LocationError>.makeStream()
        events.headings?.finish()
        events.headingGeneration &+= 1
        let generation = events.headingGeneration
        events.headings = continuation
        continuation.onTermination = { [events, manager] in
            guard events.headingGeneration == generation else { return }
            events.headings = nil
            manager.stopUpdatingHeading()
        }
        manager.startUpdatingHeading()
        return stream
    }
}

public extension LocationAuthorization {

    /// When in use or always.
    var isAuthorized: Bool {
        self == .authorizedWhenInUse || self == .authorizedAlways
    }
}

/// The delegate behind `AsyncLocationManager`.
final class LocationEvents: LocationManagerDelegate {

    let authorization = PendingCallbacks<LocationAuthorization, Never>()

    let currentLocation = PendingCallbacks<any Location, LocationError>()

    var locations: EventStream<any Location, LocationError>.Continuation?

    var locationGeneration = 0

    var headings: EventStream<any Heading, LocationError>.Continuation?

    var headingGeneration = 0

    func didChangeAuthorization(_ manager: any LocationManager, status: Int32, accuracy: Int32) {
        let status = LocationAuthorization(rawValue: status) ?? .notDetermined
        guard status != .notDetermined else { return }
        authorization.resumeAll(with: .success(status))
        if status == .denied || status == .restricted {
            currentLocation.failAll(.denied)
            locations?.finish(throwing: .denied)
            headings?.finish(throwing: .denied)
        }
    }

    func didUpdateLocations(_ manager: any LocationManager, locations: [any Location]) {
        guard let latest = locations.last else { return }
        currentLocation.resumeAll(with: .success(latest))
        for location in locations {
            self.locations?.yield(location)
        }
    }

    func didUpdateHeading(_ manager: any LocationManager, heading: any Heading) {
        headings?.yield(heading)
    }

    func didFail(_ manager: any LocationManager, error: Int32) {
        let error = LocationError(code: error) ?? .unknown
        switch error {
        case .headingFailure:
            headings?.finish(throwing: error)
        case .locationUnknown:
            // Transient while updating; final for a one-shot request.
            currentLocation.failAll(error)
        default:
            currentLocation.failAll(error)
            locations?.finish(throwing: error)
            headings?.finish(throwing: error)
        }
    }
}
#endif
