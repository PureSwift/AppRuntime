import XCTest
import DynamicLocation
import DynamicRuntime

/// Pins the location contracts.
final class DynamicLocationTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        LocationManagerProxy.descriptor, LocationManagerDelegateProxy.descriptor,
        LocationProxy.descriptor, HeadingProxy.descriptor,
    ]

    func testPermissionsFirst() {
        let manager = LocationManagerProxy.descriptor
        XCTAssertEqual(manager.capability, .location)
        for key in ["authorizationStatus", "accuracyAuthorization"] {
            XCTAssertEqual(method(manager, key), MethodDescriptor(key, "()I", .static), key)
        }
        XCTAssertEqual(method(manager, "isLocationServicesEnabled")?.kind, .static)
        XCTAssertEqual(method(manager, "make:")?.kind, .constructor)
        // Two steps: foreground first, then background; precise on demand.
        XCTAssertNotNil(method(manager, "requestWhenInUseAuthorization"))
        XCTAssertNotNil(method(manager, "requestAlwaysAuthorization"))
        XCTAssertEqual(method(manager, "requestFullAccuracy:")?.signature, Signature("(O)V"))
        XCTAssertEqual(method(LocationManagerDelegateProxy.descriptor, "didChangeAuthorization:status:accuracy:")?.signature, Signature("(OII)V"))
    }

    func testUpdates() {
        let manager = LocationManagerProxy.descriptor
        XCTAssertEqual(method(manager, "setDesiredAccuracy:")?.signature, Signature("(I)V"), "accuracy tiers, not meters")
        XCTAssertEqual(method(manager, "lastLocation")?.signature, Signature("()O"))
        XCTAssertEqual(method(LocationProxy.descriptor, "timestamp")?.signature, Signature("()J"))
        XCTAssertEqual(method(LocationProxy.descriptor, "isSimulated")?.signature, Signature("()I"))
        XCTAssertEqual(method(HeadingProxy.descriptor, "trueHeading")?.signature, Signature("()D"))
        XCTAssertEqual(method(LocationManagerDelegateProxy.descriptor, "didUpdateLocations:locations:")?.signature, Signature("(OO)V"))
    }

    func testRecordsRoundTrip() {
        XCTAssertEqual(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)), Self.descriptors)
    }

    func testCodes() {
        XCTAssertEqual(LocationAuthorization(rawValue: 4), .authorizedWhenInUse)
        XCTAssertEqual(LocationAccuracy.reduced.rawValue, 4)
    }
}
