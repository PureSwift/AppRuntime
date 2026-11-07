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

    /// Advertised service UUIDs, canonical.
    func serviceUUIDs() -> [String]

    /// UUIDs with service data, canonical.
    func serviceDataUUIDs() -> [String]

    func serviceData(_ uuid: String) -> [UInt8]?

    /// Solicited service UUIDs, canonical.
    func solicitedServiceUUIDs() -> [String]

    /// dBm; `Int32.min` if absent.
    func txPowerLevel() -> Int32

    /// `-1` unknown (Android before API 26), `0` no, `1` yes.
    func isConnectable() -> Int32
}
