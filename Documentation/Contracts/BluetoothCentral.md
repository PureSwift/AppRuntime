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
`CentralState`, `PeripheralState`, `ScanMode`, `WriteType`, `BluetoothError`.

`BluetoothUUID`, `BluetoothAddress`, `CompanyIdentifier` and
`GATTCharacteristicProperties` come from
[PureSwift/Bluetooth](https://github.com/PureSwift/Bluetooth), re-exported by
this module. Contracts can declare `BluetoothUUID` directly, because the macros
marshal any `RawRepresentable` type with `String` raw values as its string.
The wire carries only strings and integers, so non-Swift hosts never see that
package. A method returning a `BluetoothUUID` is declared `throws`, and throws
`RuntimeError.thrown` if the host's string isn't a valid UUID.

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

**No Bluetooth address on Apple platforms.** CoreBluetooth never exposes the
peer address, and Android peripherals usually advertise random private
addresses that change. `Peripheral.identifier()` is therefore a string that
is **stable for this app on this device only**:
- the `CBPeripheral.identifier` UUID on Apple platforms;
- the address on Android and Linux.

Treat it as opaque. Use it with `Central.retrievePeripherals(_:)`, and don't
share it between devices. `Peripheral.address` returns a `BluetoothAddress`
where the identifier is one, and nil on Apple platforms. Apps that need a
stable identity across devices must read one from the peripheral itself (for
example, a serial number characteristic).

**UUIDs** are `BluetoothUUID` in Swift and raw strings on the wire, in one of
the three forms that `BluetoothUUID.rawValue` produces:

| Form | Example |
|---|---|
| 16-bit | `180D` |
| 32-bit | `0000180D` |
| 128-bit | `0000180D-0000-1000-8000-00805F9B34FB` |

Only hosts that lack these forms convert:
- CoreBluetooth's `CBUUID` already uses them, so Apple hosts pass strings
  straight through.
- Android and BlueZ only have full 128-bit UUIDs. Their hosts expand short
  forms on the way in, and on the way out shorten any UUID built on the
  Bluetooth Base UUID, to 16-bit where the upper 16 bits are zero and 32-bit
  otherwise.

`BluetoothUUID` compares by form: `.bit16(0x180D)` isn't equal to the same UUID
spelled as `.bit128`. Compare `.bit128` values when the forms may differ.

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
Access to a protected attribute fails with the peripheral's ATT error while
pairing runs: `attribute` plus Insufficient Authentication (0x05) or
Insufficient Encryption (0x0F), that is 261 or 271. The app retries. The
async API throws `.insufficientAuthentication` for both, since
`BluetoothError(code:)` maps them. Hosts report `.insufficientAuthentication`
itself when pairing fails, such as when the peer removed its pairing.
Android hosts call `createBond()` on either ATT error.

**RSSI** is in dBm; `127` means unavailable, as in CoreBluetooth.

**Not portable, so not included:** peripheral role, L2CAP channels (no Linux
BlueZ parity for the central API yet), PHY selection, connection priority,
extended advertising details, and CoreBluetooth state restoration.

## Async/await

Guest code can use `AsyncCentral` and `AsyncPeripheral` instead of
delegates (§6.2.1). They are guest-side only; hosts implement the
delegate contract above and never see them.

| Call | Returns |
|---|---|
| `AsyncCentral.authorization` | current authorization, never prompts |
| `requestAuthorization()` | the outcome; prompts only if undecided |
| `waitUntilPoweredOn()` | once powered on; throws `unauthorized` or `unsupported` |
| `states()` | `EventStream<CentralState, Never>` |
| `scan(services:allowDuplicates:mode:)` | `EventStream<ScanResult, BluetoothError>`; releasing it stops the scan |
| `connect(_:timeout:)` | `AsyncPeripheral`; cancelling the task cancels the attempt |
| `disconnect(_:)` | once the host reports it |
| `AsyncPeripheral.discoverServices`, `discoverCharacteristics`, `discoverDescriptors` | the discovered objects |
| `read`, `write` (characteristics and descriptors), `readRSSI()` | the value |
| `notifications(for:)` | `EventStream<[UInt8], BluetoothError>`; releasing it unsubscribes |

Failures are `BluetoothError`; `BluetoothError(code:)` maps a delegate
code. Requests about the same attribute complete in order. A cancelled
GATT request throws `operationCancelled` at once; the native request still
completes and its result is discarded. When a peripheral disconnects,
pending calls throw the reason and notification streams finish with it.

```swift
let central = AsyncCentral()
guard await central.requestAuthorization() == .allowed else { return }
try await central.waitUntilPoweredOn()
for try await result in central.scan(services: [.bit16(0x180D)]) {
    let peripheral = try await central.connect(result.peripheral, timeout: 10_000)
    let service = try await peripheral.discoverServices([.bit16(0x180D)])[0]
    let measurement = try await peripheral.discoverCharacteristics([.bit16(0x2A37)], for: service)[0]
    for try await value in peripheral.notifications(for: measurement) {
        print(value)
    }
}
```

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
        central.scan(services: [BluetoothUUID.bit16(0x180D)], allowDuplicates: false,
                     mode: ScanMode.balanced.rawValue)
    }

    func didDiscover(_ central: Central, peripheral: Peripheral, advertisement: Advertisement, rssi: Int32) {
        central.stopScan()
        central.connect(peripheral, timeout: 10_000)
    }
    // …
}
```
