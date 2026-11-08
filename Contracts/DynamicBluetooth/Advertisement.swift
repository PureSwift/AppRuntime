import Bluetooth
import DynamicRuntime

/// Advertisement and scan response data received while scanning, in the
/// same form on every host.
@DynamicRuntime("org.pureswift.bluetooth.Advertisement")
public protocol Advertisement: AnyObject {

    func localName() -> String?

    /// Manufacturer-specific data with the 16-bit company identifier first
    /// (little-endian), as in the advertisement. Android hosts rebuild this
    /// from `ScanRecord`; with several entries, the first one.
    func manufacturerData() -> [UInt8]?

    /// Advertised service UUIDs.
    func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID]

    /// UUIDs with service data.
    func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID]

    func serviceData(_ uuid: BluetoothUUID) -> [UInt8]?

    /// Solicited service UUIDs.
    func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID]

    /// dBm; `Int32.min` if absent.
    func txPowerLevel() -> Int32

    /// `-1` unknown (Android before API 26), `0` no, `1` yes.
    func isConnectable() -> Int32
}
