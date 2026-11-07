import DynamicRuntime

/// Advertisement data received while scanning.
@DynamicRuntime("org.pureswift.bluetooth.Advertisement")
public protocol Advertisement: AnyObject {

    func localName() -> String?

    func manufacturerData() -> [UInt8]?

    func serviceUUIDs() -> [String]

    func serviceData(_ uuid: String) -> [UInt8]?

    /// `Int32.min` if absent.
    func txPowerLevel() -> Int32

    /// `-1` unknown, `0` no, `1` yes.
    func isConnectable() -> Int32
}
