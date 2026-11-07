import DynamicRuntime

/// A remote peripheral. Results of its operations arrive through its
/// `PeripheralDelegate`, carrying the objects they're about (§4.4).
///
/// The host serializes GATT operations: Android's `BluetoothGatt` runs one
/// at a time, so the host queues them, and every call gets exactly one
/// delegate callback, even if the peripheral disconnects (with
/// `BluetoothError.notConnected`).
@DynamicRuntime("org.pureswift.bluetooth.Peripheral")
public protocol Peripheral: AnyObject {

    /// Opaque identifier, stable for this app on this device. **Not** a
    /// Bluetooth address: CoreBluetooth never exposes addresses, and Android
    /// peripherals often use random private addresses. Persist it only to
    /// pass back to `Central.retrievePeripherals(_:)` on the same device.
    func identifier() -> String

    /// The GAP device name, if known (may be cached by the system).
    func name() -> String?

    /// A `PeripheralState` raw value.
    func state() -> Int32

    func setDelegate(_ delegate: PeripheralDelegate?)

    /// Discovers services (canonical UUID strings; empty for all).
    func discoverServices(_ uuids: [String])

    /// Services discovered so far.
    func services() -> [Service]

    func discoverCharacteristics(_ uuids: [String], for service: Service)

    func discoverDescriptors(for characteristic: Characteristic)

    func readValue(_ characteristic: Characteristic)

    /// `type` is a `WriteType` raw value. Writes without response report
    /// nothing; wait for `isReadyToSendWriteWithoutResponse` when
    /// `canSendWriteWithoutResponse()` is `false`.
    func writeValue(_ value: [UInt8], for characteristic: Characteristic, type: Int32)

    /// Subscribes to notifications or indications. The host writes the
    /// Client Characteristic Configuration descriptor where the platform
    /// needs it (Android).
    func setNotifyValue(_ enabled: Bool, for characteristic: Characteristic)

    func readDescriptor(_ descriptor: Descriptor)

    func writeDescriptor(_ value: [UInt8], for descriptor: Descriptor)

    /// Reads the connection's RSSI; the result arrives through `didReadRSSI`.
    func readRSSI()

    /// Largest value for one write of `type` (a `WriteType` raw value), from
    /// the negotiated ATT MTU. Android hosts request the largest MTU on
    /// connection; iOS negotiates it automatically.
    func maximumWriteLength(_ type: Int32) -> Int32

    func canSendWriteWithoutResponse() -> Bool
}
