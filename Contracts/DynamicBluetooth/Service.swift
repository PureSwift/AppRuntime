import DynamicRuntime

/// A GATT service of a peripheral.
@DynamicRuntime("org.pureswift.bluetooth.Service")
public protocol Service: AnyObject {

    /// Canonical UUID string (see `BluetoothUUID`).
    func uuid() -> String

    func isPrimary() -> Bool

    /// Characteristics discovered so far.
    func characteristics() -> [Characteristic]

    func peripheral() -> Peripheral
}
