import XCTest
import DynamicMotion
import DynamicRuntime

/// Pins the motion contracts and tests the guest-side helpers.
final class DynamicMotionTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        MotionManagerProxy.descriptor, MotionManagerDelegateProxy.descriptor,
        AltimeterProxy.descriptor, AltimeterDelegateProxy.descriptor,
        PedometerProxy.descriptor, PedometerDelegateProxy.descriptor,
        ActivityRecognizerProxy.descriptor, ActivityRecognizerDelegateProxy.descriptor,
    ]

    func testPermissions() {
        // Raw inertial sensors need no permission anywhere.
        XCTAssertNil(MotionManagerProxy.descriptor.capability)
        XCTAssertNil(method(MotionManagerProxy.descriptor, "authorizationStatus"))
        // Motion & Fitness services: permissions first.
        for descriptor in [AltimeterProxy.descriptor, PedometerProxy.descriptor, ActivityRecognizerProxy.descriptor] {
            XCTAssertEqual(descriptor.capability, Capability("motion"), descriptor.name)
            XCTAssertEqual(method(descriptor, "authorizationStatus"), MethodDescriptor("authorizationStatus", "()I", .static), descriptor.name)
            XCTAssertEqual(method(descriptor, "requestAuthorization")?.kind, .instance, descriptor.name)
            XCTAssertEqual(method(descriptor, "make:")?.kind, .constructor, descriptor.name)
        }
    }

    func testScalarSamples() {
        let delegate = MotionManagerDelegateProxy.descriptor
        XCTAssertEqual(method(delegate, "didUpdateAcceleration:x:y:z:timestamp:")?.signature, Signature("(ODDDJ)V"))
        let deviceMotion = delegate.methods.first { $0.key.hasPrefix("didUpdateDeviceMotion:") }
        XCTAssertEqual(deviceMotion?.signature, Signature("(ODDDDDDDDDDDDDJ)V"), "no objects per sample")
        XCTAssertEqual(method(MotionManagerProxy.descriptor, "start:interval:")?.signature, Signature("(ID)V"))
        XCTAssertEqual(method(PedometerDelegateProxy.descriptor, "didUpdate:steps:distance:floorsAscended:floorsDescended:start:end:")?.signature, Signature("(OJDIIJJ)V"))
    }

    func testRecordsRoundTrip() {
        XCTAssertEqual(Set(Self.descriptors.map(\.name)).count, Self.descriptors.count)
        XCTAssertEqual(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)), Self.descriptors)
    }

    // MARK: Guest helpers

    func testQuaternionRotation() {
        // 90° about z: device x maps to reference y.
        let half = (0.5).squareRoot()
        let q = Quaternion(x: 0, y: 0, z: half, w: half)
        let rotated = q.rotate(Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-12)
        XCTAssertEqual(rotated.y, 1, accuracy: 1e-12)
        XCTAssertEqual(rotated.z, 0, accuracy: 1e-12)
        XCTAssertEqual(Quaternion(x: 0, y: 0, z: 0, w: 1).rotate(Vector3(x: 1, y: 2, z: 3)), Vector3(x: 1, y: 2, z: 3))
        XCTAssertEqual(Vector3(x: 0, y: 0, z: standardGravity).magnitude, 9.80665)
    }

    func testMotionUpdatesPacksScalars() {
        let updates = MotionUpdates()
        var received: DeviceMotion?
        updates.onDeviceMotion = { received = $0 }
        let manager = FakeMotionManager()
        updates.didUpdateDeviceMotion(
            manager,
            attitudeX: 0, attitudeY: 0, attitudeZ: 0, attitudeW: 1,
            gravityX: 0, gravityY: 0, gravityZ: standardGravity,
            userAccelerationX: 1, userAccelerationY: 2, userAccelerationZ: 3,
            rotationRateX: 4, rotationRateY: 5, rotationRateZ: 6,
            timestamp: 42
        )
        XCTAssertEqual(received?.gravity, Vector3(x: 0, y: 0, z: standardGravity))
        XCTAssertEqual(received?.userAcceleration, Vector3(x: 1, y: 2, z: 3))
        XCTAssertEqual(received?.rotationRate, Vector3(x: 4, y: 5, z: 6))
        XCTAssertEqual(received?.timestamp, 42)

        var failure: (MotionSensor?, MotionError)?
        updates.onFailure = { failure = ($0, $1) }
        updates.didFail(manager, sensor: MotionSensor.gyroscope.rawValue, error: MotionError.unavailable.rawValue)
        XCTAssertEqual(failure?.0, .gyroscope)
        XCTAssertEqual(failure?.1, .unavailable)
    }
}

/// Stands in for a host manager; the adapter never calls it.
final class FakeMotionManager: MotionManager {
    static func isAvailable(_ sensor: Int32) -> Bool { false }
    static func make(_ delegate: any MotionManagerDelegate) -> FakeMotionManager { FakeMotionManager() }
    func start(_ sensor: Int32, interval: Double) { }
    func stop(_ sensor: Int32) { }
    func isActive(_ sensor: Int32) -> Bool { false }
    func minimumInterval(_ sensor: Int32) -> Double { 0 }
}
