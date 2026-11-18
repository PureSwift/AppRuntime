import Bluetooth
import DynamicRuntime

/// A remote peripheral. Results of its operations arrive through its
/// `BluetoothPeripheralDelegate`, carrying the objects they're about (§4.4).
///
/// The host serializes GATT operations: Android's `BluetoothGatt` runs one
/// at a time, so the host queues them, and every call gets exactly one
/// delegate callback, even if the peripheral disconnects (with
/// `BluetoothError.notConnected`).
@DynamicRuntime("org.pureswift.bluetooth.Peripheral")
public protocol BluetoothPeripheral: AnyObject {

    /// Identifier stable for this app on this device. A UUID on Apple
    /// platforms, which never expose addresses; the Bluetooth address on
    /// Android and Linux, where it is often a random private address. Treat
    /// it as opaque: persist it only to pass back to
    /// `BluetoothCentral.retrievePeripherals(_:)` on the same device. `address`
    /// parses it where it is an address.
    func identifier() -> String

    /// The GAP device name, if known (may be cached by the system).
    func name() -> String?

    /// A `PeripheralState` raw value.
    func state() -> Int32

    func setDelegate(_ delegate: BluetoothPeripheralDelegate?)

    /// Discovers services (empty for all).
    func discoverServices(_ uuids: [BluetoothUUID])

    /// Services discovered so far.
    func services() -> [BluetoothService]

    func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: BluetoothService)

    func discoverDescriptors(for characteristic: BluetoothCharacteristic)

    func readValue(_ characteristic: BluetoothCharacteristic)

    /// `type` is a `WriteType` raw value. Writes without response report
    /// nothing; wait for `isReadyToSendWriteWithoutResponse` when
    /// `canSendWriteWithoutResponse()` is `false`.
    func writeValue(_ value: [UInt8], for characteristic: BluetoothCharacteristic, type: Int32)

    /// Subscribes to notifications or indications. The host writes the
    /// Client Characteristic Configuration descriptor where the platform
    /// needs it (Android).
    func setNotifyValue(_ enabled: Bool, for characteristic: BluetoothCharacteristic)

    func readDescriptor(_ descriptor: BluetoothDescriptor)

    func writeDescriptor(_ value: [UInt8], for descriptor: BluetoothDescriptor)

    /// Reads the connection's RSSI; the result arrives through `didReadRSSI`.
    func readRSSI()

    /// Largest value for one write of `type` (a `WriteType` raw value), from
    /// the negotiated ATT MTU. Android hosts request the largest MTU on
    /// connection; iOS negotiates it automatically.
    func maximumWriteLength(_ type: Int32) -> Int32

    func canSendWriteWithoutResponse() -> Bool
}
