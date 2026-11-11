/// A 3-axis sample.
public struct Vector3: Equatable, Sendable {

    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Euclidean length.
    public var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

/// A unit quaternion rotating device coordinates into the reference frame.
public struct Quaternion: Equatable, Sendable {

    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// Rotates a device-frame vector into the reference frame.
    public func rotate(_ v: Vector3) -> Vector3 {
        // v' = q v q*, expanded.
        let tx = 2 * (y * v.z - z * v.y)
        let ty = 2 * (z * v.x - x * v.z)
        let tz = 2 * (x * v.y - y * v.x)
        return Vector3(
            x: v.x + w * tx + (y * tz - z * ty),
            y: v.y + w * ty + (z * tx - x * tz),
            z: v.z + w * tz + (x * ty - y * tx)
        )
    }
}

/// One fused device-motion sample.
public struct DeviceMotion: Equatable, Sendable {

    public var attitude: Quaternion

    /// m/s², +z up when lying face up.
    public var gravity: Vector3

    /// m/s², gravity removed.
    public var userAcceleration: Vector3

    /// rad/s.
    public var rotationRate: Vector3

    /// Nanoseconds since boot.
    public var timestamp: Int64

    public init(attitude: Quaternion, gravity: Vector3, userAcceleration: Vector3, rotationRate: Vector3, timestamp: Int64) {
        self.attitude = attitude
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.timestamp = timestamp
    }
}

/// Closure-based `MotionManagerDelegate` that packs the scalar callbacks
/// into structs. Guest-side only.
///
/// ```swift
/// let updates = MotionUpdates()
/// updates.onDeviceMotion = { motion in … }
/// let manager = MotionManagerProxy.make(updates)
/// manager.start(MotionSensor.deviceMotion.rawValue, interval: 1.0 / 60)
/// ```
public final class MotionUpdates: MotionManagerDelegate {

    public var onAcceleration: ((Vector3, Int64) -> Void)?

    public var onRotationRate: ((Vector3, Int64) -> Void)?

    public var onMagneticField: ((Vector3, MagneticFieldAccuracy, Int64) -> Void)?

    public var onDeviceMotion: ((DeviceMotion) -> Void)?

    public var onFailure: ((MotionSensor?, MotionError) -> Void)?

    public init() { }

    public func didUpdateAcceleration(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        onAcceleration?(Vector3(x: x, y: y, z: z), timestamp)
    }

    public func didUpdateRotationRate(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        onRotationRate?(Vector3(x: x, y: y, z: z), timestamp)
    }

    public func didUpdateMagneticField(_ manager: any MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64) {
        onMagneticField?(Vector3(x: x, y: y, z: z), MagneticFieldAccuracy(rawValue: accuracy) ?? .uncalibrated, timestamp)
    }

    public func didUpdateDeviceMotion(
        _ manager: any MotionManager,
        attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        userAccelerationX: Double, userAccelerationY: Double, userAccelerationZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double,
        timestamp: Int64
    ) {
        onDeviceMotion?(DeviceMotion(
            attitude: Quaternion(x: attitudeX, y: attitudeY, z: attitudeZ, w: attitudeW),
            gravity: Vector3(x: gravityX, y: gravityY, z: gravityZ),
            userAcceleration: Vector3(x: userAccelerationX, y: userAccelerationY, z: userAccelerationZ),
            rotationRate: Vector3(x: rotationRateX, y: rotationRateY, z: rotationRateZ),
            timestamp: timestamp
        ))
    }

    public func didFail(_ manager: any MotionManager, sensor: Int32, error: Int32) {
        onFailure?(MotionSensor(rawValue: sensor), MotionError(rawValue: error) ?? .unknown)
    }
}
