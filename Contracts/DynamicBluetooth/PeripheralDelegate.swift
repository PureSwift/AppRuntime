import DynamicRuntime

/// Receives `BluetoothPeripheral` results on the main thread. `error` is a
/// `BluetoothError` raw value, `0` on success.
@DynamicCallback("org.pureswift.bluetooth.PeripheralDelegate")
public protocol BluetoothPeripheralDelegate: AnyObject {

    func didDiscoverServices(_ peripheral: BluetoothPeripheral, error: Int32)

    func didDiscoverCharacteristics(_ peripheral: BluetoothPeripheral, service: BluetoothService, error: Int32)

    func didDiscoverDescriptors(_ peripheral: BluetoothPeripheral, characteristic: BluetoothCharacteristic, error: Int32)

    /// A read completed, or a notification or indication arrived.
    func didUpdateValue(_ peripheral: BluetoothPeripheral, characteristic: BluetoothCharacteristic, value: [UInt8], error: Int32)

    func didWriteValue(_ peripheral: BluetoothPeripheral, characteristic: BluetoothCharacteristic, error: Int32)

    func didUpdateNotificationState(_ peripheral: BluetoothPeripheral, characteristic: BluetoothCharacteristic, error: Int32)

    func didUpdateDescriptorValue(_ peripheral: BluetoothPeripheral, descriptor: BluetoothDescriptor, value: [UInt8], error: Int32)

    func didWriteDescriptorValue(_ peripheral: BluetoothPeripheral, descriptor: BluetoothDescriptor, error: Int32)

    /// `rssi` is in dBm.
    func didReadRSSI(_ peripheral: BluetoothPeripheral, rssi: Int32, error: Int32)

    /// Writes without response can be sent again.
    func isReadyToSendWriteWithoutResponse(_ peripheral: BluetoothPeripheral)

    /// The peripheral changed its GATT database; rediscover services.
    func didModifyServices(_ peripheral: BluetoothPeripheral)

    func didUpdateName(_ peripheral: BluetoothPeripheral)
}
