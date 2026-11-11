import DynamicRuntime

/// Receives `Central` events, always on the main thread.
@DynamicCallback("org.pureswift.bluetooth.CentralDelegate")
public protocol CentralDelegate: AnyObject {

    /// `status` is a `BluetoothAuthorization` raw value.
    func didChangeAuthorization(_ central: Central, status: Int32)

    /// `state` is a `CentralState` raw value.
    func didUpdateState(_ central: Central, state: Int32)

    /// One advertisement. `rssi` is in dBm; `127` if unavailable.
    func didDiscover(_ central: Central, peripheral: Peripheral, advertisement: Advertisement, rssi: Int32)

    /// Scanning stopped on its own. `error` is a `BluetoothError` raw value,
    /// for example `.scanThrottled` (Android allows 5 scan starts per 30 s).
    func didStopScanning(_ central: Central, error: Int32)

    func didConnect(_ central: Central, peripheral: Peripheral)

    /// `error` is a `BluetoothError` raw value.
    func didFailToConnect(_ central: Central, peripheral: Peripheral, error: Int32)

    /// `error` is `0` after `cancelConnection`, otherwise a `BluetoothError`
    /// raw value.
    func didDisconnect(_ central: Central, peripheral: Peripheral, error: Int32)
}
