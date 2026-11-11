import DynamicRuntime

/// Receives `Peripheral` results on the main thread. `error` is a
/// `BluetoothError` raw value, `0` on success.
@DynamicCallback("org.pureswift.bluetooth.PeripheralDelegate")
public protocol PeripheralDelegate: AnyObject {

    func didDiscoverServices(_ peripheral: Peripheral, error: Int32)

    func didDiscoverCharacteristics(_ peripheral: Peripheral, service: Service, error: Int32)

    func didDiscoverDescriptors(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)

    /// A read completed, or a notification or indication arrived.
    func didUpdateValue(_ peripheral: Peripheral, characteristic: Characteristic, value: [UInt8], error: Int32)

    func didWriteValue(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)

    func didUpdateNotificationState(_ peripheral: Peripheral, characteristic: Characteristic, error: Int32)

    func didUpdateDescriptorValue(_ peripheral: Peripheral, descriptor: Descriptor, value: [UInt8], error: Int32)

    func didWriteDescriptorValue(_ peripheral: Peripheral, descriptor: Descriptor, error: Int32)

    /// `rssi` is in dBm.
    func didReadRSSI(_ peripheral: Peripheral, rssi: Int32, error: Int32)

    /// Writes without response can be sent again.
    func isReadyToSendWriteWithoutResponse(_ peripheral: Peripheral)

    /// The peripheral changed its GATT database; rediscover services.
    func didModifyServices(_ peripheral: Peripheral)

    func didUpdateName(_ peripheral: Peripheral)
}
