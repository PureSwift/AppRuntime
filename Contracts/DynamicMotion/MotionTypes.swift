/// Guest-side names for the integer codes the Motion contracts carry.

/// `MotionManager` sensors.
public enum MotionSensor: Int32, Sendable, CaseIterable {
    case accelerometer = 0
    case gyroscope = 1
    case magnetometer = 2
    /// Fused attitude, gravity, user acceleration and rotation rate.
    case deviceMotion = 3
}

/// Motion & Fitness authorization (iOS) / `ACTIVITY_RECOGNITION` (Android).
public enum MotionAuthorization: Int32, Sendable {
    case notDetermined = 0
    case restricted = 1
    /// Only Settings can change it.
    case denied = 2
    case authorized = 3
}

/// `ActivityRecognizerDelegate.didUpdateActivity` flags.
public struct MotionActivity: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static var stationary: Self { Self(rawValue: 0x01) }
    public static var walking: Self { Self(rawValue: 0x02) }
    public static var running: Self { Self(rawValue: 0x04) }
    public static var automotive: Self { Self(rawValue: 0x08) }
    public static var cycling: Self { Self(rawValue: 0x10) }
    public static var unknown: Self { Self(rawValue: 0x20) }
}

public enum ActivityConfidence: Int32, Sendable {
    case low = 0
    case medium = 1
    case high = 2
}

/// `MotionManagerDelegate.didUpdateMagneticField` accuracy.
public enum MagneticFieldAccuracy: Int32, Sendable {
    case uncalibrated = -1
    case low = 0
    case medium = 1
    case high = 2
}

/// Delegate `error` codes. `0` is success.
public enum MotionError: Int32, Error, Sendable {
    case unknown = 1
    /// Motion & Fitness access is missing.
    case unauthorized = 2
    /// The sensor or service doesn't exist on this device.
    case unavailable = 3
    /// The host has no history for the requested dates.
    case historyUnavailable = 4
    /// The app is in the background, where updates stop.
    case suspended = 5
    /// The waiting task was cancelled. The async wrappers throw it; hosts
    /// never send it.
    case cancelled = 6
}

/// Standard gravity in m/s², used to convert from g.
public let standardGravity = 9.80665

public extension MotionError {

    /// The error for a delegate `error` code: `nil` for `0`, success; codes
    /// this version doesn't know are `unknown`.
    init?(code: Int32) {
        guard code != 0 else { return nil }
        self = MotionError(rawValue: code) ?? .unknown
    }
}
