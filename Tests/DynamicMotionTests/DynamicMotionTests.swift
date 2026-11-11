import Testing
import DynamicMotion
import DynamicRuntime

/// Pins the motion contracts and tests the guest-side helpers.
@Suite struct DynamicMotionTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        MotionManagerProxy.descriptor, MotionManagerDelegateProxy.descriptor,
        AltimeterProxy.descriptor, AltimeterDelegateProxy.descriptor,
        PedometerProxy.descriptor, PedometerDelegateProxy.descriptor,
        ActivityRecognizerProxy.descriptor, ActivityRecognizerDelegateProxy.descriptor,
    ]

    @Test func inertialSensorsNeedNoPermission() {
        #expect(MotionManagerProxy.descriptor.capability == nil)
        #expect(method(MotionManagerProxy.descriptor, "authorizationStatus") == nil)
    }

    @Test(arguments: [AltimeterProxy.descriptor, PedometerProxy.descriptor, ActivityRecognizerProxy.descriptor])
    func fitnessServicesArePermissionsFirst(_ descriptor: ContractDescriptor) {
        #expect(descriptor.capability == Capability("motion"))
        #expect(method(descriptor, "authorizationStatus") == MethodDescriptor("authorizationStatus", "()I", .static))
        #expect(method(descriptor, "requestAuthorization")?.kind == .instance)
        #expect(method(descriptor, "make:")?.kind == .constructor)
    }

    @Test func scalarSamples() {
        let delegate = MotionManagerDelegateProxy.descriptor
        #expect(method(delegate, "didUpdateAcceleration:x:y:z:timestamp:")?.signature == Signature("(ODDDJ)V"))
        let deviceMotion = delegate.methods.first { $0.key.hasPrefix("didUpdateDeviceMotion:") }
        #expect(deviceMotion?.signature == Signature("(ODDDDDDDDDDDDDJ)V"), "no objects per sample")
        #expect(method(MotionManagerProxy.descriptor, "start:interval:")?.signature == Signature("(ID)V"))
        #expect(method(PedometerDelegateProxy.descriptor, "didUpdate:steps:distance:floorsAscended:floorsDescended:start:end:")?.signature == Signature("(OJDIIJJ)V"))
    }

    @Test func recordsRoundTrip() {
        #expect(Set(Self.descriptors.map(\.name)).count == Self.descriptors.count)
        #expect(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)) == Self.descriptors)
    }

    // MARK: Guest helpers

    @Test func quaternionRotation() {
        // 90° about z: device x maps to reference y.
        let half = (0.5).squareRoot()
        let rotated = Quaternion(x: 0, y: 0, z: half, w: half).rotate(Vector3(x: 1, y: 0, z: 0))
        #expect(abs(rotated.x) < 1e-12)
        #expect(abs(rotated.y - 1) < 1e-12)
        #expect(abs(rotated.z) < 1e-12)
        #expect(Quaternion(x: 0, y: 0, z: 0, w: 1).rotate(Vector3(x: 1, y: 2, z: 3)) == Vector3(x: 1, y: 2, z: 3))
        #expect(Vector3(x: 0, y: 0, z: standardGravity).magnitude == 9.80665)
    }

    @Test func motionUpdatesPacksScalars() {
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
        #expect(received?.gravity == Vector3(x: 0, y: 0, z: standardGravity))
        #expect(received?.userAcceleration == Vector3(x: 1, y: 2, z: 3))
        #expect(received?.rotationRate == Vector3(x: 4, y: 5, z: 6))
        #expect(received?.timestamp == 42)

        var failure: (MotionSensor?, MotionError)?
        updates.onFailure = { failure = ($0, $1) }
        updates.didFail(manager, sensor: MotionSensor.gyroscope.rawValue, error: MotionError.unavailable.rawValue)
        #expect(failure?.0 == .gyroscope)
        #expect(failure?.1 == .unavailable)
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
