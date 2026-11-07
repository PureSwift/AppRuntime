import XCTest
import DynamicNFC
import DynamicRuntime

/// Pins the NFC reader contracts.
final class DynamicNFCTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        NFCReaderProxy.descriptor, NFCReaderDelegateProxy.descriptor, NFCTagProxy.descriptor,
        NDEFMessageProxy.descriptor, NDEFRecordProxy.descriptor,
    ]

    func testAvailabilityFirst() {
        let reader = NFCReaderProxy.descriptor
        XCTAssertEqual(reader.capability, Capability("nfc"))
        XCTAssertEqual(method(reader, "availability"), MethodDescriptor("availability", "()I", .static))
        XCTAssertEqual(method(reader, "make:")?.kind, .constructor)
        // The scan sheet is the consent: there is no separate request.
        XCTAssertFalse(reader.methods.contains { $0.key.lowercased().contains("authoriz") })
        XCTAssertEqual(method(reader, "begin:alertMessage:")?.signature, Signature("(IO)V"))
        XCTAssertEqual(method(reader, "invalidate:")?.signature, Signature("(O)V"))
    }

    func testReaderRole() {
        let tag = NFCTagProxy.descriptor
        XCTAssertEqual(method(tag, "identifier")?.signature, Signature("()O"))
        XCTAssertEqual(method(tag, "transceive:")?.signature, Signature("(O)V"))
        XCTAssertEqual(method(tag, "writeNDEF:")?.signature, Signature("(O)V"))
        XCTAssertEqual(method(NFCReaderDelegateProxy.descriptor, "didReadNDEF:tag:message:error:")?.signature, Signature("(OOOI)V"))
        XCTAssertEqual(method(NFCReaderDelegateProxy.descriptor, "didInvalidate:error:message:")?.signature, Signature("(OIO)V"))
        let keys = Self.descriptors.flatMap { $0.methods.map(\.key) }
        XCTAssertFalse(keys.contains { $0.lowercased().contains("emulat") }, "no card emulation")
    }

    func testNDEF() {
        let record = NDEFRecordProxy.descriptor
        XCTAssertEqual(method(record, "make:type:identifier:payload:"), MethodDescriptor("make:type:identifier:payload:", "(IOOO)O", .constructor))
        XCTAssertEqual(method(record, "makeURI:"), MethodDescriptor("makeURI:", "(O)O", .constructor), "failable")
        XCTAssertEqual(method(record, "makeText:locale:")?.kind, .constructor)
        XCTAssertEqual(method(NDEFMessageProxy.descriptor, "make:")?.signature, Signature("(O)O"))
    }

    func testRecordsRoundTrip() {
        XCTAssertEqual(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)), Self.descriptors)
    }

    func testCodes() {
        XCTAssertTrue(NFCTagTypes(rawValue: 0x0A).contains(.iso18092))
        XCTAssertEqual(NFCAvailability(rawValue: 1), .disabled)
        XCTAssertEqual(NDEFTypeNameFormat.wellKnown.rawValue, 1)
    }
}
