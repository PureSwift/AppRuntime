import DynamicRuntime

/// The device the app runs on: model, system, battery, power, thermal
/// state, orientation and proximity.
///
/// No permission is needed on any host, so this contract has no
/// capability. It never exposes hardware identifiers (serial number, IMEI,
/// Bluetooth or Wi-Fi MAC, UDID): iOS doesn't provide them and Android 10+
/// restricts them.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / tvOS / visionOS | `UIDevice`, `ProcessInfo`, `sysctl` |
/// | macOS | `ProcessInfo`, IOKit power sources |
/// | Android | `Build`, `BatteryManager`, `PowerManager`, `SensorManager` |
/// | Linux | `/etc/os-release`, DMI / device tree, UPower |
@DynamicRuntime("org.pureswift.device.Device")
public protocol Device: AnyObject {

    /// The device. Changes arrive through the delegate set with
    /// `setDelegate(_:)`.
    static func current() -> Self

    func setDelegate(_ delegate: DeviceDelegate?)

    // MARK: Identity

    /// The user-assigned name. iOS 16+ returns a generic name ("iPhone")
    /// unless the app has the user-assigned-device-name entitlement;
    /// Android uses `Settings.Global.DEVICE_NAME`.
    func name() -> String

    /// Marketing model family, for example "iPhone", "iPad", "Pixel 8".
    func model() -> String

    /// Hardware model identifier, for example "iPhone16,1" or Android
    /// `Build.MODEL`.
    func modelIdentifier() -> String

    /// For example "Apple", "Google", "Samsung".
    func manufacturer() -> String

    /// For example "iOS", "iPadOS", "macOS", "tvOS", "visionOS", "watchOS",
    /// "Android", "Linux".
    func systemName() -> String

    /// For example "17.4", "14", "6.6".
    func systemVersion() -> String

    /// Android API level (`Build.VERSION.SDK_INT`); `-1` elsewhere.
    func apiLevel() -> Int32

    /// A `DeviceIdiom` raw value.
    func idiom() -> Int32

    /// A UUID string that stays the same for apps from this vendor on this
    /// device, and changes when all of them are uninstalled. iOS
    /// `identifierForVendor`; Android hosts store a random UUID per signing
    /// key. Nil before the device is first unlocked (iOS).
    func vendorIdentifier() -> String?

    func isSimulator() -> Bool

    // MARK: Resources

    /// Physical memory in bytes.
    func physicalMemory() -> Int64

    func processorCount() -> Int32

    /// Milliseconds since boot, monotonic.
    func uptime() -> Int64

    // MARK: Power

    /// Battery reporting is off until enabled (iOS
    /// `isBatteryMonitoringEnabled`); level and state read as unknown before.
    func setBatteryMonitoringEnabled(_ enabled: Bool)

    /// 0–1, or `-1` if unknown or the device has no battery.
    func batteryLevel() -> Float

    /// A `BatteryState` raw value.
    func batteryState() -> Int32

    /// Low Power Mode (iOS) / Battery Saver (Android).
    func isLowPowerModeEnabled() -> Bool

    /// A `ThermalState` raw value.
    func thermalState() -> Int32

    // MARK: Orientation and proximity

    /// Orientation reporting is off until enabled; `orientation()` reads as
    /// unknown before.
    func setOrientationUpdatesEnabled(_ enabled: Bool)

    /// A `DeviceOrientation` raw value: the physical orientation, which may
    /// differ from the UI's.
    func orientation() -> Int32

    /// Turns the proximity sensor on; the screen may turn off while
    /// something is near. Stays off on devices without one; check
    /// `isProximityMonitoringEnabled()`.
    func setProximityMonitoringEnabled(_ enabled: Bool)

    func isProximityMonitoringEnabled() -> Bool

    /// Whether something is close to the sensor.
    func proximityState() -> Bool
}
