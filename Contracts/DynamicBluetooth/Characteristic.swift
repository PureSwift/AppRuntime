import DynamicRuntime

/// A GATT characteristic of a service.
@DynamicRuntime("org.pureswift.bluetooth.Characteristic")
public protocol Characteristic: AnyObject {

    /// Canonical UUID string (see `BluetoothUUID`).
    func uuid() -> String

    /// `CharacteristicProperties` raw value.
    func properties() -> Int32

    /// The last value read or notified, if any.
    func value() -> [UInt8]?

    func isNotifying() -> Bool

    /// Descriptors discovered so far.
    func descriptors() -> [Descriptor]

    func service() -> Service
}
