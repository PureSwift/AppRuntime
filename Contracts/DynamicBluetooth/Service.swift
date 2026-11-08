import Bluetooth
import DynamicRuntime

/// A GATT service of a peripheral.
@DynamicRuntime("org.pureswift.bluetooth.Service")
public protocol Service: AnyObject {

    /// In the shortest form that represents it. Throws if the host's string
    /// isn't a valid UUID.
    func uuid() throws(RuntimeError) -> BluetoothUUID

    func isPrimary() -> Bool

    /// Characteristics discovered so far.
    func characteristics() -> [Characteristic]

    func peripheral() -> Peripheral
}
