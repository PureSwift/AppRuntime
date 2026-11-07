import XCTest
import DynamicBluetooth
import DynamicFormatting
import DynamicLocation
import DynamicNetworking
import DynamicRuntime

/// The provider contracts are declarations; these tests pin their runtime
/// names, capabilities, method keys and wire signatures, which hosts
/// implement against.
final class ContractsTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func testBluetooth() throws {
        let central = CentralProxy.descriptor
        XCTAssertEqual(central.name, "org.pureswift.bluetooth.Central")
        XCTAssertEqual(central.capability, .bluetooth)
        XCTAssertEqual(method(central, "make:"), MethodDescriptor("make:", "(O)O", .constructor))
        XCTAssertEqual(method(central, "scan:allowDuplicates:")?.signature, Signature("(OZ)V"))
        XCTAssertEqual(CentralDelegateProxy.descriptor.kind, .callback)
        XCTAssertEqual(method(PeripheralProxy.descriptor, "writeValue:for:withResponse:")?.signature, Signature("(OOZ)V"))
        XCTAssertEqual(method(PeripheralDelegateProxy.descriptor, "didUpdateValue:characteristic:value:error:")?.signature, Signature("(OOOI)V"))
        XCTAssertEqual(method(AdvertisementProxy.descriptor, "serviceData:")?.signature, Signature("(O)O"))
        XCTAssertNil(PeripheralProxy.descriptor.capability, "only Central is gated")
        XCTAssertTrue(CharacteristicProperties(rawValue: 0x12).contains(.notify))
    }

    func testLocation() {
        let manager = LocationManagerProxy.descriptor
        XCTAssertEqual(manager.capability, .location)
        XCTAssertEqual(method(manager, "lastLocation")?.signature, Signature("()O"))
        XCTAssertEqual(method(LocationProxy.descriptor, "timestamp")?.signature, Signature("()J"))
        XCTAssertEqual(method(LocationManagerDelegateProxy.descriptor, "didUpdateLocations:locations:")?.signature, Signature("(OO)V"))
    }

    func testNetworking() {
        XCTAssertEqual(HTTPClientProxy.descriptor.capability, .network)
        let request = HTTPRequestProxy.descriptor
        XCTAssertEqual(method(request, "make:method:"), MethodDescriptor("make:method:", "(OO)O", .constructor), "failable constructor")
        XCTAssertEqual(method(request, "setTimeout:")?.signature, Signature("(D)V"))
        let url = ParsedURLProxy.descriptor
        XCTAssertEqual(url.name, "org.pureswift.network.URL")
        XCTAssertEqual(method(url, "parse:")?.kind, .constructor)
        XCTAssertEqual(method(url, "encodeQueryValue:")?.kind, .static)
        XCTAssertEqual(method(url, "port")?.signature, Signature("()I"))
    }

    func testFormatting() {
        XCTAssertEqual(method(NumberFormatProxy.descriptor, "make:style:"), MethodDescriptor("make:style:", "(OI)O", .constructor))
        XCTAssertEqual(method(DateFormatProxy.descriptor, "formatRelative:reference:")?.signature, Signature("(JJ)O"))
        XCTAssertEqual(method(LocaleInfoProxy.descriptor, "preferredLanguages")?.kind, .static)
        XCTAssertNil(LocaleInfoProxy.descriptor.capability)
    }

    func testEveryContractRecordRoundTrips() {
        let descriptors = [
            CentralProxy.descriptor, CentralDelegateProxy.descriptor, PeripheralProxy.descriptor,
            PeripheralDelegateProxy.descriptor, ServiceProxy.descriptor, CharacteristicProxy.descriptor,
            AdvertisementProxy.descriptor, LocationManagerProxy.descriptor,
            LocationManagerDelegateProxy.descriptor, LocationProxy.descriptor, HTTPClientProxy.descriptor,
            HTTPRequestProxy.descriptor, HTTPResponseProxy.descriptor, HTTPTaskProxy.descriptor,
            HTTPTaskDelegateProxy.descriptor, ParsedURLProxy.descriptor, NumberFormatProxy.descriptor,
            DateFormatProxy.descriptor, LocaleInfoProxy.descriptor,
        ]
        XCTAssertEqual(Set(descriptors.map(\.name)).count, descriptors.count, "names are unique")
        XCTAssertEqual(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)), descriptors)
    }
}
