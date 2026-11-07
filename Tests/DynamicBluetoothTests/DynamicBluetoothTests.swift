import XCTest
import DynamicBluetooth
import DynamicRuntime

/// Pins the Bluetooth LE central contracts and tests the guest-side helpers.
final class DynamicBluetoothTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        CentralProxy.descriptor, CentralDelegateProxy.descriptor, PeripheralProxy.descriptor,
        PeripheralDelegateProxy.descriptor, ServiceProxy.descriptor, CharacteristicProxy.descriptor,
        DescriptorProxy.descriptor, AdvertisementProxy.descriptor,
    ]

    func testPermissionsFirst() {
        let central = CentralProxy.descriptor
        XCTAssertEqual(central.capability, .bluetooth)
        // Checking never needs an instance, and making one never prompts.
        XCTAssertEqual(method(central, "authorizationStatus"), MethodDescriptor("authorizationStatus", "()I", .static))
        XCTAssertEqual(method(central, "make:"), MethodDescriptor("make:", "(O)O", .constructor))
        XCTAssertEqual(method(central, "requestAuthorization")?.signature, Signature("()V"))
        XCTAssertEqual(method(CentralDelegateProxy.descriptor, "didChangeAuthorization:status:")?.signature, Signature("(OI)V"))
        // Only the central is gated; everything else comes from it.
        XCTAssertEqual(Self.descriptors.filter { $0.capability != nil }.map(\.name), ["org.pureswift.bluetooth.Central"])
    }

    func testCentral() {
        let central = CentralProxy.descriptor
        XCTAssertEqual(method(central, "scan:allowDuplicates:mode:")?.signature, Signature("(OZI)V"))
        XCTAssertEqual(method(central, "connect:timeout:")?.signature, Signature("(OI)V"))
        XCTAssertEqual(method(central, "retrievePeripherals:")?.signature, Signature("(O)O"))
        XCTAssertEqual(method(CentralDelegateProxy.descriptor, "didDiscover:peripheral:advertisement:rssi:")?.signature, Signature("(OOOI)V"))
        XCTAssertNil(central.methods.first { $0.key.lowercased().contains("advertis") && $0.kind != .instance },
                     "central role only")
    }

    func testPeripheralHasNoAddress() {
        let keys = PeripheralProxy.descriptor.methods.map(\.key)
        XCTAssertTrue(keys.contains("identifier"))
        XCTAssertFalse(keys.contains { $0.lowercased().contains("address") || $0.lowercased().contains("mac") })
        XCTAssertEqual(method(PeripheralProxy.descriptor, "writeValue:for:type:")?.signature, Signature("(OOI)V"))
        XCTAssertEqual(method(PeripheralProxy.descriptor, "maximumWriteLength:")?.signature, Signature("(I)I"))
        XCTAssertEqual(method(PeripheralProxy.descriptor, "setDelegate:")?.signature, Signature("(O)V"))
        XCTAssertEqual(method(PeripheralDelegateProxy.descriptor, "didUpdateValue:characteristic:value:error:")?.signature, Signature("(OOOI)V"))
    }

    func testRecordsRoundTrip() {
        XCTAssertEqual(Set(Self.descriptors.map(\.name)).count, Self.descriptors.count)
        XCTAssertEqual(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)), Self.descriptors)
    }

    // MARK: Guest helpers

    func testCanonicalUUIDs() {
        let heartRate = "0000180D-0000-1000-8000-00805F9B34FB"
        XCTAssertEqual(BluetoothUUID.canonical("180D"), heartRate)
        XCTAssertEqual(BluetoothUUID.canonical("0x180d"), heartRate)
        XCTAssertEqual(BluetoothUUID.canonical("0000180d"), heartRate)
        XCTAssertEqual(BluetoothUUID.canonical("0000180d-0000-1000-8000-00805f9b34fb"), heartRate)
        XCTAssertEqual(BluetoothUUID.canonical("0000180D00001000800000805F9B34FB"), heartRate)
        XCTAssertEqual(BluetoothUUID.canonical("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"), "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        XCTAssertNil(BluetoothUUID.canonical("180"))
        XCTAssertNil(BluetoothUUID.canonical("XYZW"))
        XCTAssertNil(BluetoothUUID.canonical(""))
    }

    func testShortForm() {
        XCTAssertEqual(BluetoothUUID.shortForm("0000180D-0000-1000-8000-00805F9B34FB"), "180D")
        XCTAssertNil(BluetoothUUID.shortForm("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"))
    }

    func testCodes() {
        XCTAssertTrue(CharacteristicProperties(rawValue: 0x12).contains(.notify))
        XCTAssertEqual(BluetoothError.attribute.rawValue + 0x05, 261, "ATT insufficient authentication")
    }
}
