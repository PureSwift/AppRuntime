# Bluetooth LE Central

Module `DynamicBluetooth`. Central role only: scan, connect, and use a
peripheral's GATT services. Advertising and serving GATT (the peripheral
role) are not part of the contract.

| Contract | Kind | Wraps |
|---|---|---|
| `Central` | contract, `requires: .bluetooth` | `CBCentralManager` · `BluetoothLeScanner` + `BluetoothAdapter` · BlueZ `Adapter1` |
| `CentralDelegate` | callback | `CBCentralManagerDelegate` · `ScanCallback` + `BluetoothGattCallback` (connection) |
| `Peripheral` | contract | `CBPeripheral` · `BluetoothDevice` + `BluetoothGatt` · BlueZ `Device1` |
| `PeripheralDelegate` | callback | `CBPeripheralDelegate` · `BluetoothGattCallback` |
| `Service`, `Characteristic`, `Descriptor` | contracts | `CBService` … · `BluetoothGattService` … · `GattService1` … |
| `Advertisement` | contract | advertisement dictionary · `ScanRecord` · `Device1` properties |

Guest-side Swift (never crosses the ABI): `BluetoothAuthorization`,
`CentralState`, `PeripheralState`, `ScanMode`, `WriteType`,
`CharacteristicProperties`, `BluetoothError`, `BluetoothUUID`.

## Permissions first

Every host requires the user's consent before any radio use, and each asks
differently. The contract makes the steps explicit and the same everywhere:

```swift
switch BluetoothAuthorization(rawValue: CentralProxy.authorizationStatus()) {
case .allowed:       break                          // go ahead
case .notDetermined: explainThen { central.requestAuthorization() }
case .denied, .restricted, .none: showSettingsHint() // only the user can change it
}
```

1. `Central.authorizationStatus()` is static and **never prompts**.
2. `Central.make(_:)` **never prompts**. iOS hosts create the
   `CBCentralManager` lazily, because creating one shows the prompt.
3. `requestAuthorization()` is the only call that may show a prompt. Call
   it from a user action. The result arrives as
   `didChangeAuthorization`, followed by `didUpdateState`.
4. Until the status is `.allowed` and the state is `.poweredOn`, every
   operation fails, with `BluetoothError.unauthorized` / `.poweredOff`, or
   the state stays `.unauthorized`.

| Host | What `requestAuthorization()` does | Manifest (`.bluetooth`) |
|---|---|---|
| iOS 13+ / macOS | creates the `CBCentralManager`, which prompts once | `NSBluetoothAlwaysUsageDescription` |
| Android 12+ | requests `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` | both, with `usesPermissionFlags="neverForLocation"` |
| Android 6–11 | requests `ACCESS_FINE_LOCATION`; scanning also needs Location services on | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (`maxSdkVersion="30"`) |
| Linux distro | no prompt; reports `.allowed` if the sandbox grants the bus, else `.restricted` | system D-Bus bound into the sandbox (§7.8) |

After a denial, iOS never prompts again, and Android stops prompting after
"Don't ask again". Both report `.denied`, and the app should point the user
to Settings.

## Platform limitations the contract accounts for

**No Bluetooth address.** CoreBluetooth never exposes the peer address, and
Android peripherals usually advertise random private addresses that change.
`Peripheral.identifier()` is therefore an **opaque string, stable for this
app on this device only**:
- the `CBPeripheral.identifier` UUID on Apple platforms;
- the address on Android and Linux.

Don't parse it or share it between devices. Use it only with
`Central.retrievePeripherals(_:)`. Apps that need a stable identity across
devices must read one from the peripheral itself (for example, a serial
number characteristic).

**UUIDs** are always the canonical 128-bit uppercase form
(`0000180D-0000-1000-8000-00805F9B34FB`). Hosts convert CoreBluetooth's
short forms and Android's lowercase strings. `BluetoothUUID.canonical(_:)`
converts app input.

**Manufacturer data** is always the raw AD structure payload, with the
company identifier first, which is what CoreBluetooth reports. Android
hosts rebuild it from `ScanRecord.getManufacturerSpecificData()`.

**One GATT operation at a time.** Android's `BluetoothGatt` fails a second
operation issued before the first completes. Hosts queue operations
per peripheral. Every call gets exactly one delegate callback, including
`BluetoothError.notConnected` if the link drops while it is queued.

**Notifications.** `setNotifyValue` writes the Client Characteristic
Configuration descriptor on Android. CoreBluetooth forbids writing it
directly.

**MTU.** Android hosts request the largest MTU (517) after connecting;
iOS negotiates automatically. `maximumWriteLength(_:)` reports the
usable payload for either write type.

**Connection timeout.** `CBCentralManager.connect` never times out, and
Android's direct connect gives up after about 30 s. The host enforces the
`timeout` argument itself and reports `.connectionTimeout`.

**Scan throttling.** Android rejects a scan started more than 5 times in
30 s. It does so silently on some versions, so hosts report
`didStopScanning(…, error: .scanThrottled)`.

**Background.** iOS only discovers peripherals in the background when
`services` is non-empty, and coalesces duplicates. The contract doesn't
promise background scanning; apps that need it declare it in the manifest's
platform escape hatch.

**Pairing** has no API on iOS: the system pairs when an encrypted attribute
is accessed. The contract therefore exposes no pairing calls on any host.
Access to a protected attribute fails with `.insufficientAuthentication`
while pairing runs, and the app retries. Android hosts call `createBond()`
in that case.

**RSSI** is in dBm; `127` means unavailable, as in CoreBluetooth.

**Not portable, so not included:** peripheral role, L2CAP channels (no Linux
BlueZ parity for the central API yet), PHY selection, connection priority,
extended advertising details, and CoreBluetooth state restoration.

## Threading

Every delegate method runs on the main thread (§6.4). Hosts hop from
CoreBluetooth's queue, Android's Binder threads, or the D-Bus loop first.

## Example

```swift
final class Scanner: CentralDelegate {
    var central: CentralProxy?

    func start() {
        central = CentralProxy.make(self)
        if CentralProxy.authorizationStatus() == BluetoothAuthorization.notDetermined.rawValue {
            central?.requestAuthorization()
        }
    }

    func didUpdateState(_ central: Central, state: Int32) {
        guard state == CentralState.poweredOn.rawValue else { return }
        central.scan(services: [BluetoothUUID.canonical("180D")!], allowDuplicates: false,
                     mode: ScanMode.balanced.rawValue)
    }

    func didDiscover(_ central: Central, peripheral: Peripheral, advertisement: Advertisement, rssi: Int32) {
        central.stopScan()
        central.connect(peripheral, timeout: 10_000)
    }
    // …
}
```
