import Testing
import DynamicBluetooth
import DynamicRuntime

/// Pins the Bluetooth LE central contracts and tests the guest-side helpers.
@Suite struct DynamicBluetoothTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        CentralProxy.descriptor, CentralDelegateProxy.descriptor, PeripheralProxy.descriptor,
        PeripheralDelegateProxy.descriptor, ServiceProxy.descriptor, CharacteristicProxy.descriptor,
        DescriptorProxy.descriptor, AdvertisementProxy.descriptor,
    ]

    @Test func permissionsFirst() {
        let central = CentralProxy.descriptor
        #expect(central.capability == .bluetooth)
        // Checking never needs an instance, and making one never prompts.
        #expect(method(central, "authorizationStatus") == MethodDescriptor("authorizationStatus", "()I", .static))
        #expect(method(central, "make:") == MethodDescriptor("make:", "(O)O", .constructor))
        #expect(method(central, "requestAuthorization")?.signature == Signature("()V"))
        #expect(method(CentralDelegateProxy.descriptor, "didChangeAuthorization:status:")?.signature == Signature("(OI)V"))
        // Only the central is gated; everything else comes from it.
        #expect(Self.descriptors.filter { $0.capability != nil }.map(\.name) == ["org.pureswift.bluetooth.Central"])
    }

    @Test func centralRoleOnly() {
        let central = CentralProxy.descriptor
        #expect(method(central, "scan:allowDuplicates:mode:")?.signature == Signature("(OZI)V"))
        #expect(method(central, "connect:timeout:")?.signature == Signature("(OI)V"))
        #expect(method(central, "retrievePeripherals:")?.signature == Signature("(O)O"))
        #expect(method(CentralDelegateProxy.descriptor, "didDiscover:peripheral:advertisement:rssi:")?.signature == Signature("(OOOI)V"))
        let keys = Self.descriptors.flatMap { $0.methods.map { $0.key.lowercased() } }
        #expect(!keys.contains { $0.hasPrefix("startadvertising") || $0.hasPrefix("addservice") })
    }

    @Test func peripheralHasNoAddress() {
        let keys = PeripheralProxy.descriptor.methods.map(\.key)
        #expect(keys.contains("identifier"))
        #expect(!keys.contains { $0.lowercased().contains("address") || $0.lowercased().contains("mac") })
        #expect(method(PeripheralProxy.descriptor, "writeValue:for:type:")?.signature == Signature("(OOI)V"))
        #expect(method(PeripheralProxy.descriptor, "maximumWriteLength:")?.signature == Signature("(I)I"))
        #expect(method(PeripheralProxy.descriptor, "setDelegate:")?.signature == Signature("(O)V"))
        #expect(method(PeripheralDelegateProxy.descriptor, "didUpdateValue:characteristic:value:error:")?.signature == Signature("(OOOI)V"))
    }

    @Test func recordsRoundTrip() {
        #expect(Set(Self.descriptors.map(\.name)).count == Self.descriptors.count)
        #expect(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)) == Self.descriptors)
    }

    // MARK: Guest helpers

    @Test(arguments: ["180D", "0x180d", "0000180d", "0000180d-0000-1000-8000-00805f9b34fb", "0000180D00001000800000805F9B34FB"])
    func canonicalUUID(_ input: String) {
        #expect(BluetoothUUID.canonical(input) == "0000180D-0000-1000-8000-00805F9B34FB")
    }

    @Test func canonicalUUIDEdgeCases() {
        #expect(BluetoothUUID.canonical("6E400001-B5A3-F393-E0A9-E50E24DCCA9E") == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(BluetoothUUID.canonical("180") == nil)
        #expect(BluetoothUUID.canonical("XYZW") == nil)
        #expect(BluetoothUUID.canonical("") == nil)
    }

    @Test func shortForm() {
        #expect(BluetoothUUID.shortForm("0000180D-0000-1000-8000-00805F9B34FB") == "180D")
        #expect(BluetoothUUID.shortForm("6E400001-B5A3-F393-E0A9-E50E24DCCA9E") == nil)
    }

    @Test func codes() {
        #expect(CharacteristicProperties(rawValue: 0x12).contains(.notify))
        #expect(BluetoothError.attribute.rawValue + 0x05 == 261, "ATT insufficient authentication")
    }
}
