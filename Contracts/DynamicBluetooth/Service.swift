import DynamicRuntime

/// A GATT service of a peripheral.
@DynamicRuntime("org.pureswift.bluetooth.Service")
public protocol Service: AnyObject {

    func uuid() -> String

    func isPrimary() -> Bool

    func characteristics() -> [Characteristic]
}
