import DynamicRuntime

/// Receives `Central` events on the main thread.
@DynamicCallback("org.pureswift.bluetooth.CentralDelegate")
public protocol CentralDelegate: AnyObject {

    func didUpdateState(_ central: Central)

    func didDiscover(_ peripheral: Peripheral, advertisement: Advertisement, rssi: Int32)

    func didConnect(_ peripheral: Peripheral)

    /// `error` is a `BluetoothError` raw value.
    func didFailToConnect(_ peripheral: Peripheral, error: Int32)

    /// `error` is `0` for a requested disconnection.
    func didDisconnect(_ peripheral: Peripheral, error: Int32)
}
