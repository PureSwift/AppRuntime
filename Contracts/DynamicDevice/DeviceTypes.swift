/// Guest-side names for the integer codes the Device contracts carry.

/// `Device.idiom()`.
public enum DeviceIdiom: Int32, Sendable {
    case unspecified = 0
    case phone = 1
    case pad = 2
    case tv = 3
    case car = 4
    case watch = 5
    /// macOS, Linux desktops, Chromebooks.
    case desktop = 6
    case vision = 7
}

/// `Device.batteryState()`.
public enum BatteryState: Int32, Sendable {
    /// Monitoring is off, or the device has no battery.
    case unknown = 0
    case unplugged = 1
    case charging = 2
    case full = 3
}

/// `Device.thermalState()`. Android maps `PowerManager` thermal status
/// (API 29+): none/light → nominal, moderate → fair, severe → serious,
/// critical and above → critical.
public enum ThermalState: Int32, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
}

/// `Device.orientation()`.
public enum DeviceOrientation: Int32, Sendable {
    case unknown = 0
    case portrait = 1
    case portraitUpsideDown = 2
    /// Top of the device to the left.
    case landscapeLeft = 3
    case landscapeRight = 4
    case faceUp = 5
    case faceDown = 6
}
