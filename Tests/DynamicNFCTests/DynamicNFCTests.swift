import Testing
import DynamicNFC
import DynamicRuntime

/// Pins the NFC reader contracts.
@Suite struct DynamicNFCTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        NFCReaderProxy.descriptor, NFCReaderDelegateProxy.descriptor, NFCTagProxy.descriptor,
        NDEFMessageProxy.descriptor, NDEFRecordProxy.descriptor,
    ]

    @Test func availabilityFirst() {
        let reader = NFCReaderProxy.descriptor
        #expect(reader.capability == Capability("nfc"))
        #expect(method(reader, "availability") == MethodDescriptor("availability", "()I", .static))
        #expect(method(reader, "make:")?.kind == .constructor)
        // The scan sheet is the consent: there is no separate request.
        #expect(!reader.methods.contains { $0.key.lowercased().contains("authoriz") })
        #expect(method(reader, "begin:alertMessage:")?.signature == Signature("(IO)V"))
        #expect(method(reader, "invalidate:")?.signature == Signature("(O)V"))
    }

    @Test func readerRoleOnly() {
        let tag = NFCTagProxy.descriptor
        #expect(method(tag, "identifier")?.signature == Signature("()O"))
        #expect(method(tag, "transceive:")?.signature == Signature("(O)V"))
        #expect(method(tag, "writeNDEF:")?.signature == Signature("(O)V"))
        #expect(method(NFCReaderDelegateProxy.descriptor, "didReadNDEF:tag:message:error:")?.signature == Signature("(OOOI)V"))
        #expect(method(NFCReaderDelegateProxy.descriptor, "didInvalidate:error:message:")?.signature == Signature("(OIO)V"))
        let keys = Self.descriptors.flatMap { $0.methods.map(\.key) }
        #expect(!keys.contains { $0.lowercased().contains("emulat") }, "no card emulation")
    }

    @Test func ndef() {
        let record = NDEFRecordProxy.descriptor
        #expect(method(record, "make:type:identifier:payload:") == MethodDescriptor("make:type:identifier:payload:", "(IOOO)O", .constructor))
        #expect(method(record, "makeURI:") == MethodDescriptor("makeURI:", "(O)O", .constructor), "failable constructor")
        #expect(method(record, "makeText:locale:")?.kind == .constructor)
        #expect(method(NDEFMessageProxy.descriptor, "make:")?.signature == Signature("(O)O"))
    }

    @Test func recordsRoundTrip() {
        #expect(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)) == Self.descriptors)
    }

    @Test func codes() {
        #expect(NFCTagTypes(rawValue: 0x0A).contains(.iso18092))
        #expect(NFCAvailability(rawValue: 1) == .disabled)
        #expect(NDEFTypeNameFormat.wellKnown.rawValue == 1)
    }
}
