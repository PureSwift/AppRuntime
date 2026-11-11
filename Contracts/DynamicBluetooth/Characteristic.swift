import Bluetooth
import DynamicRuntime

/// A GATT characteristic of a service.
@DynamicRuntime("org.pureswift.bluetooth.Characteristic")
public protocol Characteristic: AnyObject {

    /// In the shortest form that represents it. Throws if the host's string
    /// isn't a valid UUID.
    func uuid() throws(RuntimeError) -> BluetoothUUID

    /// `GATTCharacteristicProperties` raw value; `gattProperties` wraps it.
    func properties() -> Int32

    /// The last value read or notified, if any.
    func value() -> [UInt8]?

    func isNotifying() -> Bool

    /// Descriptors discovered so far.
    func descriptors() -> [Descriptor]

    func service() -> Service
}
