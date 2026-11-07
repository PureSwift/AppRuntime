import DynamicRuntime

/// A remote peripheral. Results arrive through its `PeripheralDelegate`,
/// which carries the objects they're about (§4.4).
@DynamicRuntime("org.pureswift.bluetooth.Peripheral")
public protocol Peripheral: AnyObject {

    /// Stable identifier on this host (a UUID on Apple platforms, the
    /// address elsewhere).
    func identifier() -> String

    func name() -> String?

    func setDelegate(_ delegate: PeripheralDelegate)

    func discoverServices(_ uuids: [String])

    func services() -> [Service]

    func discoverCharacteristics(_ uuids: [String], for service: Service)

    func readValue(_ characteristic: Characteristic)

    func writeValue(_ value: [UInt8], for characteristic: Characteristic, withResponse: Bool)

    func setNotifyValue(_ enabled: Bool, for characteristic: Characteristic)
}
