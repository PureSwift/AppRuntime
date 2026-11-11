# Location

Module `DynamicLocation`: device position and compass heading.

| Contract | Kind | Wraps |
|---|---|---|
| `LocationManager` | contract, `requires: .location` | `CLLocationManager` · `FusedLocationProviderClient` / `LocationManager` · GeoClue 2 |
| `LocationManagerDelegate` | callback | `CLLocationManagerDelegate` · `LocationCallback` |
| `Location` | contract | `CLLocation` · `android.location.Location` · GeoClue `Location` |
| `Heading` | contract | `CLHeading` · rotation-vector sensor (host-computed) |

Guest-side Swift: `LocationAuthorization`, `LocationAccuracyAuthorization`,
`LocationAccuracy`, `LocationError`.

## Permissions first

Location is the most layered permission on every platform. The contract
exposes each layer instead of hiding it:

1. **Services enabled.** Check the static `isLocationServicesEnabled()`.
   When location is off system-wide, no prompt can appear and requests fail
   with `.servicesDisabled`.
2. **Status.** The static `authorizationStatus()` and
   `accuracyAuthorization()` never prompt. `make(_:)` never prompts either;
   the delegate receives `didChangeAuthorization` once with the current
   values.
3. **Foreground.** `requestWhenInUseAuthorization()`, called from a user
   action.
4. **Precise, on demand.** If the user picked approximate, call
   `requestFullAccuracy(_:)` when a feature needs it.
5. **Background, last.** `requestAlwaysAuthorization()`, only after step 3
   succeeded, and only if the manifest declares background location.

| Step | iOS | Android | Linux |
|---|---|---|---|
| 3 | `requestWhenInUseAuthorization`; `NSLocationWhenInUseUsageDescription` | runtime request for `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION`; the user may grant only coarse (12+) | GeoClue agent authorizes the app ID |
| 4 | `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)`, for one session | request `ACCESS_FINE_LOCATION` again | n/a (`.full`) |
| 5 | `requestAlwaysAuthorization`; `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes: location`; the prompt may be deferred until the app uses location in the background | API 29: runtime request for `ACCESS_BACKGROUND_LOCATION`; **API 30+: no prompt**, the host opens the app's location settings page | n/a |

Both iOS and Android show no prompt again after a denial; the status is
`.denied` and only Settings can change it.

## Platform limitations the contract accounts for

**Approximate location.** On iOS 14+ and Android 12+, the user can grant
approximate location only:
- the coordinate is offset by design;
- `horizontalAccuracy` is large (iOS reduced accuracy is ~1–20 km; Android
  coarse is ~2 km);
- `accuracyAuthorization()` reports `.reduced`.

Apps must work with it, or ask for precise location with
`requestFullAccuracy(_:)`.

**Accuracy is a tier, not meters.** Android picks a provider priority
rather than honoring a radius, so `setDesiredAccuracy(_:)` takes a
`LocationAccuracy` tier that maps onto both platforms (table in
`LocationTypes.swift`).

**No Google Play services.** On Android devices without Play services, the
fused provider is unavailable. Hosts fall back to the framework
`LocationManager` (GPS and network providers). Fixes are slower and
`isSimulated` may be `-1`.

**Background.**
- iOS needs `authorizedAlways`, `UIBackgroundModes: location` and
  `allowsBackgroundLocationUpdates`.
- Android needs `ACCESS_BACKGROUND_LOCATION` and a foreground service with
  a visible notification.

`setBackgroundUpdatesEnabled(_:)` asks the host to do whatever its platform
requires, and fails with `.backgroundNotAllowed` when it can't.

**Heading.** iOS reports `CLHeading`. Android has no heading API, so the
host derives one from the rotation-vector sensor and computes true heading
with `GeomagneticField` once a location is known. Linux reports
`isHeadingAvailable() == false`. True heading stays negative until a
location is known.

**Mock locations.** `isSimulated()` maps `Location.isMock` (Android 12+) /
`isFromMockProvider`, and `CLLocationSourceInformation.isSimulatedBySoftware`
(iOS 15+). It is `-1` where neither exists.

**Units.** Degrees (WGS 84), meters, meters per second, degrees from true
north, and milliseconds since 1970 UTC for timestamps.

**Not included in v1:** geocoding (Android's `Geocoder` may have no
backend), region monitoring and geofencing (limits of 20 regions on iOS,
100 on Android, plus Play services), significant-change and visit
monitoring, indoor floors.

## Threading

Every delegate method runs on the main thread (§6.4).

## Example

```swift
final class Tracker: LocationManagerDelegate {
    var manager: LocationManagerProxy?

    func start() {
        guard LocationManagerProxy.isLocationServicesEnabled() else { return showServicesOff() }
        manager = LocationManagerProxy.make(self)
    }

    func didChangeAuthorization(_ manager: LocationManager, status: Int32, accuracy: Int32) {
        switch LocationAuthorization(rawValue: status) {
        case .notDetermined: manager.requestWhenInUseAuthorization()   // from a user action
        case .authorizedWhenInUse, .authorizedAlways:
            manager.setDesiredAccuracy(LocationAccuracy.hundredMeters.rawValue)
            manager.startUpdatingLocation()
        default: showSettingsHint()
        }
    }
    // …
}
```
