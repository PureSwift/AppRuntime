import Bluetooth
import DynamicRuntime

/// A GATT descriptor of a characteristic.
///
/// CoreBluetooth doesn't allow writing the Client Characteristic
/// Configuration descriptor (0x2902); use `Peripheral.setNotifyValue`.
@DynamicRuntime("org.pureswift.bluetooth.Descriptor")
public protocol Descriptor: AnyObject {

    /// In the shortest form that represents it. Throws if the host's string
    /// isn't a valid UUID.
    func uuid() throws(RuntimeError) -> BluetoothUUID

    /// The last value read, if any, as raw bytes.
    func value() -> [UInt8]?

    func characteristic() -> Characteristic
}
