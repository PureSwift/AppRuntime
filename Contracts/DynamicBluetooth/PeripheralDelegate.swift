import DynamicRuntime

/// Receives `Peripheral` results on the main thread. `error` is a
/// `BluetoothError` raw value, `0` on success.
@DynamicCallback("org.pureswift.bluetooth.PeripheralDelegate")
public protocol PeripheralDelegate: AnyObject {

    func didDiscoverServices(_ peripheral: Peripheral, error: Int32)

    func didDiscoverCharacteristics(_ peripheral: Peripheral, service: Service, error: Int32)

    func didUpdateValue(_ peripheral: Peripheral, characteristic: Characteristic, value: [UInt8], error: Int32)

    func didWriteValue(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)

    func didUpdateNotificationState(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)
}
