import DynamicRuntime

/// A Bluetooth LE central: scans for, connects to and retrieves peripherals.
/// Central role only; this contract never advertises or serves GATT.
///
/// Permissions first: check `authorizationStatus()` (never prompts), create
/// the central (never prompts), then call `requestAuthorization()` from a
/// user action. Until the delegate reports `BluetoothAuthorization.allowed`
/// and `CentralState.poweredOn`, every operation fails with
/// `BluetoothError.unauthorized` or `.poweredOff`.
///
/// | Host | Implementation | Permission |
/// |---|---|---|
/// | iOS / macOS | `CBCentralManager`, created lazily so `make` doesn't prompt | `NSBluetoothAlwaysUsageDescription` |
/// | Android 12+ | `BluetoothLeScanner` + `BluetoothGatt` | `BLUETOOTH_SCAN` (`neverForLocation`) + `BLUETOOTH_CONNECT` |
/// | Android ≤ 11 | same | `ACCESS_FINE_LOCATION` |
/// | Linux | BlueZ D-Bus (`org.bluez`) | sandbox `bluetooth` capability |
@DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
public protocol Central: AnyObject {

    /// The app's Bluetooth authorization, a `BluetoothAuthorization` raw
    /// value. Never prompts.
    static func authorizationStatus() -> Int32

    /// Creates a central. Never prompts; the delegate receives the current
    /// state soon after.
    static func make(_ delegate: CentralDelegate) -> Self

    /// Shows the system permission prompt if the status is `notDetermined`;
    /// the result arrives through `didChangeAuthorization`. Call it in
    /// response to a user action, after explaining why.
    func requestAuthorization()

    /// A `CentralState` raw value.
    func state() -> Int32

    /// Scans for peripherals advertising any of `services` (canonical UUID
    /// strings; empty for all). iOS doesn't discover peripherals in the
    /// background without `services`. `mode` is a `ScanMode` raw value and
    /// only affects Android.
    func scan(services: [String], allowDuplicates: Bool, mode: Int32)

    func stopScan()

    func isScanning() -> Bool

    /// Connects to `peripheral`. `timeout` is in milliseconds; `0` waits
    /// indefinitely (the host enforces the timeout, since CoreBluetooth has
    /// none). Results arrive through `didConnect` / `didFailToConnect`.
    func connect(_ peripheral: Peripheral, timeout: Int32)

    /// Cancels a pending or active connection.
    func cancelConnection(_ peripheral: Peripheral)

    /// Peripherals this app saw before, by `Peripheral.identifier()`.
    /// Unknown identifiers are skipped.
    func retrievePeripherals(_ identifiers: [String]) -> [Peripheral]

    /// Peripherals already connected to the system (by any app) that expose
    /// any of `services`.
    func retrieveConnectedPeripherals(_ services: [String]) -> [Peripheral]
}
