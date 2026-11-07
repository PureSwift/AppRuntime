import XCTest
import DynamicDevice
import DynamicRuntime

/// Pins the device contracts.
final class DynamicDeviceTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func testNoPermissionsOrHardwareIdentifiers() {
        let device = DeviceProxy.descriptor
        XCTAssertNil(device.capability)
        XCTAssertEqual(method(device, "current"), MethodDescriptor("current", "()O", .constructor))
        let keys = device.methods.map { $0.key.lowercased() }
        for forbidden in ["serial", "imei", "mac", "udid", "address", "authoriz"] {
            XCTAssertFalse(keys.contains { $0.contains(forbidden) }, forbidden)
        }
        XCTAssertEqual(method(device, "vendorIdentifier")?.signature, Signature("()O"), "nullable")
    }

    func testProperties() {
        let device = DeviceProxy.descriptor
        XCTAssertEqual(method(device, "batteryLevel")?.signature, Signature("()F"))
        XCTAssertEqual(method(device, "physicalMemory")?.signature, Signature("()J"))
        XCTAssertEqual(method(device, "apiLevel")?.signature, Signature("()I"))
        XCTAssertEqual(method(device, "setDelegate:")?.signature, Signature("(O)V"))
        XCTAssertEqual(method(DeviceDelegateProxy.descriptor, "didChangeBatteryLevel:level:")?.signature, Signature("(OF)V"))
        XCTAssertEqual(method(DeviceDelegateProxy.descriptor, "didChangeProximityState:near:")?.signature, Signature("(OZ)V"))
    }

    func testRecordsRoundTrip() {
        let descriptors = [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor]
        XCTAssertEqual(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)), descriptors)
    }

    func testCodes() {
        XCTAssertEqual(DeviceIdiom(rawValue: 6), .desktop)
        XCTAssertEqual(ThermalState.critical.rawValue, 3)
        XCTAssertEqual(DeviceOrientation(rawValue: 5), .faceUp)
    }
}
