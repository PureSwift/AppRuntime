import DynamicRuntime

/// A GATT characteristic of a service.
@DynamicRuntime("org.pureswift.bluetooth.Characteristic")
public protocol Characteristic: AnyObject {

    func uuid() -> String

    /// `CharacteristicProperties` raw value.
    func properties() -> Int32
}
