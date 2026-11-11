import DynamicRuntime

/// Receives `Device` changes on the main thread, once the matching updates
/// are enabled.
@DynamicCallback("org.pureswift.device.DeviceDelegate")
public protocol DeviceDelegate: AnyObject {

    /// `level` is 0–1, or `-1` if unknown.
    func didChangeBatteryLevel(_ device: Device, level: Float)

    /// `state` is a `BatteryState` raw value.
    func didChangeBatteryState(_ device: Device, state: Int32)

    func didChangeLowPowerMode(_ device: Device, enabled: Bool)

    /// `state` is a `ThermalState` raw value.
    func didChangeThermalState(_ device: Device, state: Int32)

    /// `orientation` is a `DeviceOrientation` raw value.
    func didChangeOrientation(_ device: Device, orientation: Int32)

    func didChangeProximityState(_ device: Device, near: Bool)
}
