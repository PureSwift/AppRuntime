# Motion

Module `DynamicMotion`: inertial sensors, barometer, pedometer and
activity recognition.

| Contract | Kind | iOS | Android | Linux |
|---|---|---|---|---|
| `MotionManager` | contract (no capability) | `CMMotionManager` | `SensorManager` | iio-sensor-proxy |
| `MotionManagerDelegate` | callback | | | |
| `Altimeter` | contract, `requires: "motion"` | `CMAltimeter` | `TYPE_PRESSURE` | — |
| `Pedometer` | contract, `requires: "motion"` | `CMPedometer` | `TYPE_STEP_COUNTER` | — |
| `ActivityRecognizer` | contract, `requires: "motion"` | `CMMotionActivityManager` | `ActivityRecognitionClient` (Play services) | — |
| `…Delegate` for each | callbacks | | | |

Guest-side Swift: `MotionSensor`, `MotionAuthorization`, `MotionActivity`,
`ActivityConfidence`, `MagneticFieldAccuracy`, `MotionError`,
`standardGravity`, and the `Vector3`, `Quaternion`, `DeviceMotion` structs
with the `MotionUpdates` closure adapter.

## Permissions first

Raw inertial sensors need no permission on any platform, so
`MotionManager` has no capability and no authorization calls. Check
`isAvailable(_:)` and start.

The "Motion & Fitness" services do need permission. Each of their contracts
follows the same steps as the other modules:

1. The static `authorizationStatus()` never prompts.
2. `make(_:)` never prompts.
3. `requestAuthorization()` from a user action; the result arrives through
   `didChangeAuthorization`.
4. Until the status is `.authorized`, updates fail with
   `MotionError.unauthorized`.

| Service | iOS | Android |
|---|---|---|
| Altimeter | Motion & Fitness (`NSMotionUsageDescription`) | none (reports `.authorized`) |
| Pedometer | Motion & Fitness | `ACTIVITY_RECOGNITION` (API 29+, runtime) |
| ActivityRecognizer | Motion & Fitness | `ACTIVITY_RECOGNITION`, plus Google Play services |

The manifest capability `motion` adds the usage string and permissions.
On iOS, the one Motion & Fitness permission covers all three services.

## One convention for samples

The two platforms disagree on units, signs and timestamps. Hosts convert
everything to one convention, so app code never branches on the platform:

| Quantity | Contract | iOS source | Android source |
|---|---|---|---|
| Acceleration, gravity, user acceleration | m/s²; at rest face up, z ≈ +9.81 | g, opposite sign: host multiplies by −9.80665 | m/s², same sign |
| Rotation rate | rad/s, right-hand rule | same | same |
| Magnetic field | µT | same | same |
| Attitude | quaternion rotating device coordinates into a frame with z vertical and an arbitrary fixed x | `CMAttitude` in `xArbitraryZVertical` (host converts to this convention) | `TYPE_GAME_ROTATION_VECTOR` |
| Sample timestamp | nanoseconds since boot, monotonic | `CMLogItem.timestamp` × 10⁹ | `SensorEvent.timestamp` |
| Pedometer / activity dates | milliseconds since 1970 UTC | `Date` | wall clock |

Axes are relative to the device's **natural orientation**: x to the right,
y toward the top, z out of the screen. They don't follow UI rotation, and
some Android tablets have a landscape natural orientation.

## Platform limitations the contract accounts for

**High-rate samples are scalars.** A 100 Hz device-motion stream as objects
would cost one dispatch plus about a dozen getter calls per sample. The
delegate methods take the values as arguments instead, so each sample is
one dispatch. `MotionUpdates` packs them into structs on the guest side.
This deliberately departs from "structured data is objects with getters"
(§4.4), because the data is high-frequency and fixed-shape.

**Sample rates.** iOS delivers up to about 100 Hz. Android 12+ caps at
200 Hz unless the app holds `HIGH_SAMPLING_RATE_SENSORS`. Hosts clamp the
requested interval and report the limit through `minimumInterval(_:)`.

**Fused motion on Android.** The host combines `TYPE_GAME_ROTATION_VECTOR`,
`TYPE_GRAVITY`, `TYPE_LINEAR_ACCELERATION` and `TYPE_GYROSCOPE` into one
`didUpdateDeviceMotion` call per sample. Where a device lacks the
software sensors, `isAvailable(.deviceMotion)` is `false`.

**Pedometer history.**
- iOS keeps 7 days, so `query(from:to:)` works and `startUpdates(from:)`
  can start in the past.
- Android's step counter only counts since boot and keeps no history, so
  `isHistoryAvailable()` is `false` and counts start at `startUpdates`.
- Distance and floors are iOS only; the delegate reports `nan` / `-1`.

**Activity recognition on Android** needs Google Play services. Devices
without them report `isAvailable() == false`. Results are transitions,
reported with the activity and a confidence; several flags may be set at
once.

**Background.** iOS stops inertial updates when the app leaves the
foreground (`MotionError.suspended`). Android keeps them only while the
process runs. The contract promises foreground delivery only.

**Linux.** iio-sensor-proxy exposes an accelerometer orientation, a
compass and a light sensor on some hardware. Hosts report what they can and
`isAvailable` is `false` for the rest.

## Async/await

Guest code can use the async wrappers instead of delegates (§6.2.1). They
are guest-side only; hosts never see them.

| Wrapper | Streams and calls |
|---|---|
| `AsyncMotionManager` | `acceleration`, `rotationRate` (`MotionSample`), `magneticField` (`MagneticFieldSample`), `deviceMotion` (`DeviceMotion`), each with an interval and a buffering policy |
| `AsyncPedometer` | `requestAuthorization()`, `updates(from:)` (`PedometerData`), `query(from:to:)` |
| `AsyncAltimeter` | `requestAuthorization()`, `updates()` (`AltitudeSample`) |
| `AsyncActivityRecognizer` | `requestAuthorization()`, `updates()` (`ActivitySample`) |

Streams are `EventStream<…, MotionError>`; a sensor runs while its stream
is alive. `.newest(n)` buffering keeps only recent samples when the
consumer falls behind. `cancelled` (6) is a guest-side code: the wrappers
throw it, hosts never send it.

## Threading

Every delegate method runs on the main thread (§6.4). Hosts hop from
CoreMotion's operation queue or Android's sensor thread first.

## Example

```swift
let updates = MotionUpdates()
updates.onDeviceMotion = { motion in
    let up = motion.attitude.rotate(Vector3(x: 0, y: 0, z: 1))
    render(tilt: up)
}
if MotionManagerProxy.isAvailable(MotionSensor.deviceMotion.rawValue) {
    let manager = MotionManagerProxy.make(updates)
    manager.start(MotionSensor.deviceMotion.rawValue, interval: 1.0 / 60)
}
```
