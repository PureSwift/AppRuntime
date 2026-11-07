import DynamicRuntime

/// A Bluetooth LE central: scans for and connects to peripherals (§4).
///
/// Implemented over CoreBluetooth (`CBCentralManager`), Android's
/// `BluetoothLeScanner` + `BluetoothGatt`, or BlueZ / BluetoothLinux.
@DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
public protocol Central: AnyObject {

    static func make(_ delegate: CentralDelegate) -> Self

    /// A `CentralState` raw value.
    func state() -> Int32

    /// Scans for peripherals advertising any of `services` (all if empty).
    func scan(services: [String], allowDuplicates: Bool)

    func stopScan()

    func connect(_ peripheral: Peripheral)

    func disconnect(_ peripheral: Peripheral)
}
