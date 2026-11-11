# Device

Module `DynamicDevice`: what `UIDevice` provides, in a form every host can
supply. Model and system, battery and power, thermal state, physical
orientation, and proximity.

| Contract | Kind | iOS | Android | Linux |
|---|---|---|---|---|
| `Device` | contract (no capability) | `UIDevice`, `ProcessInfo`, `sysctl` | `Build`, `BatteryManager`, `PowerManager`, `Settings.Global` | `/etc/os-release`, DMI / device tree, UPower, `/proc` |
| `DeviceDelegate` | callback | `UIDevice` / `ProcessInfo` notifications | broadcast receivers, `OnThermalStatusChangedListener` | UPower D-Bus signals |

Guest-side Swift: `DeviceIdiom`, `BatteryState`, `ThermalState`,
`DeviceOrientation`.

## Permissions

None. Everything here is readable without a prompt on every host, so the
contract has no capability and no authorization calls. Two values are
**opt-in** instead, because reading them costs power:
- battery: `setBatteryMonitoringEnabled(_:)`;
- orientation: `setOrientationUpdatesEnabled(_:)`.

Before they're enabled, their getters report unknown, as `UIDevice` does.

## Platform limitations the contract accounts for

**No hardware identifiers.** iOS gives apps no serial number, IMEI, MAC
address or UDID, and Android 10+ restricts all of them to privileged apps.
The contract offers only `vendorIdentifier()`:

| Host | Value | Resets when |
|---|---|---|
| iOS | `identifierForVendor` | every app from the vendor is uninstalled |
| Android | a random UUID the host stores in the app's data, per signing key | the app's data is cleared or it is uninstalled |
| Linux | a random UUID the host stores in the app's container | the container is removed |

Use it for analytics or for de-duplicating installs, not as a durable
device identity. iOS returns nil before the device is first unlocked after
a restart.

**Device name is private on iOS 16+.** `name()` returns a generic name
("iPhone") unless the app holds the
`com.apple.developer.device-information.user-assigned-device-name`
entitlement. Android reads `Settings.Global.DEVICE_NAME` (API 25+), falling
back to the model.

**Model strings differ by platform:**
- `model()` is the family name the user knows ("iPhone", "iPad", "Pixel 8").
- `modelIdentifier()` is the machine name ("iPhone16,1", Android
  `Build.MODEL`, DMI `product_name`).

Map identifiers to marketing names in the app if needed; no host provides
that mapping.

**Battery** is missing on desktops, TVs and many Linux boards, which report
`-1` and `.unknown`. iOS rounds the level to 5% steps.

**Thermal state** comes from `ProcessInfo.thermalState` on Apple
platforms. Android's `PowerManager.getCurrentThermalStatus` (API 29+) has
seven levels, which map onto four (see `ThermalState`). Older Android
reports `.nominal`.

**Orientation** is physical, from the accelerometer, and includes face up
and face down. It can differ from the UI's orientation when rotation is
locked. Renderers own UI orientation (§9).

**Proximity** exists on phones only. On other devices,
`setProximityMonitoringEnabled(true)` leaves `isProximityMonitoringEnabled()`
false. On iOS the screen turns off while something is near; Android hosts
hold a `PROXIMITY_SCREEN_OFF_WAKE_LOCK` for the same behavior.

**Not included:**
- screen size and scale, which belong to the renderer;
- disk space, which WASI can report for the app's container;
- locale, which is in `DynamicFormatting`;
- carrier and network type, which belong to a future network-path contract;
- haptics.

## Async/await

Guest code can use `AsyncDevice` instead of the delegate (§6.2.1). It's
guest-side only; hosts never see it.

`events(battery:orientation:proximity:)` returns an
`EventStream<DeviceEvent, Never>` of battery, low power, thermal,
orientation and proximity changes. It turns on the monitoring it asks for,
and turns it off again, and removes the delegate, when the stream is
released.

## Threading

Every delegate method runs on the main thread (§6.4).

## Example

```swift
final class Power: DeviceDelegate {
    let device = DeviceProxy.current()

    init() {
        device.setDelegate(self)
        device.setBatteryMonitoringEnabled(true)
    }

    func didChangeBatteryLevel(_ device: Device, level: Float) {
        if level >= 0, level < 0.2 { reduceWork() }
    }

    func didChangeThermalState(_ device: Device, state: Int32) {
        if state >= ThermalState.serious.rawValue { pauseAnimations() }
    }
    // …
}
```
