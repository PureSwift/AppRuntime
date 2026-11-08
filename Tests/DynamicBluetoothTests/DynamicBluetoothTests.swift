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

    // MARK: UUID strings

    @Test(arguments: [
        ("180D", BluetoothUUID.bit16(0x180D)),
        ("0000180D", BluetoothUUID.bit32(0x180D)),
    ])
    func shortUUIDForms(_ string: String, _ uuid: BluetoothUUID) {
        #expect(BluetoothUUID(rawValue: string) == uuid)
        #expect(uuid.rawValue == string)
    }

    @Test func fullUUIDForm() throws {
        let string = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        let uuid = try #require(BluetoothUUID(rawValue: string))
        #expect(uuid.rawValue == string)
    }

    @Test func formsCompareAfterExpanding() throws {
        let full = try #require(BluetoothUUID(rawValue: "0000180D-0000-1000-8000-00805F9B34FB"))
        #expect(BluetoothUUID.bit16(0x180D) != full, "BluetoothUUID compares by form")
        #expect(BluetoothUUID.bit16(0x180D).bit128 == full.bit128)
    }

    @Test(arguments: ["180", "XYZW", "", "0000180D-0000"])
    func invalidUUIDStrings(_ string: String) {
        #expect(BluetoothUUID(rawValue: string) == nil)
    }

    // MARK: Accessors

    @Test func addressOnlyWhereTheIdentifierIsOne() {
        #expect(FakePeripheral(identifier: "AA:BB:CC:DD:EE:FF").address?.rawValue == "AA:BB:CC:DD:EE:FF")
        #expect(FakePeripheral(identifier: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E").address == nil)
    }

    @Test func companyIdentifier() {
        #expect(FakeAdvertisement(manufacturer: [0x4C, 0x00, 0x02]).companyIdentifier == CompanyIdentifier(rawValue: 0x004C))
        #expect(FakeAdvertisement(manufacturer: [0x4C]).companyIdentifier == nil)
        #expect(FakeAdvertisement(manufacturer: nil).companyIdentifier == nil)
    }

    @Test func uuidsAreStringsOnTheWire() {
        #expect(method(ServiceProxy.descriptor, "uuid")?.signature == Signature("()O"))
        #expect(method(AdvertisementProxy.descriptor, "serviceUUIDs")?.signature == Signature("()O"))
        #expect(method(AdvertisementProxy.descriptor, "serviceData:")?.signature == Signature("(O)O"))
    }

    @Test func codes() {
        #expect(GATTCharacteristicProperties(rawValue: 0x12).contains(.notify))
        #expect(BluetoothError.attribute.rawValue + 0x05 == 261, "ATT insufficient authentication")
    }
}

// MARK: - Fakes

final class FakePeripheral: Peripheral {
    let identifierString: String
    init(identifier: String) { identifierString = identifier }
    func identifier() -> String { identifierString }
    func name() -> String? { nil }
    func state() -> Int32 { 0 }
    func setDelegate(_ delegate: (any PeripheralDelegate)?) { }
    func discoverServices(_ uuids: [BluetoothUUID]) { }
    func services() -> [any Service] { [] }
    func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any Service) { }
    func discoverDescriptors(for characteristic: any Characteristic) { }
    func readValue(_ characteristic: any Characteristic) { }
    func writeValue(_ value: [UInt8], for characteristic: any Characteristic, type: Int32) { }
    func setNotifyValue(_ enabled: Bool, for characteristic: any Characteristic) { }
    func readDescriptor(_ descriptor: any Descriptor) { }
    func writeDescriptor(_ value: [UInt8], for descriptor: any Descriptor) { }
    func readRSSI() { }
    func maximumWriteLength(_ type: Int32) -> Int32 { 20 }
    func canSendWriteWithoutResponse() -> Bool { true }
}

final class FakeAdvertisement: Advertisement {
    let manufacturer: [UInt8]?
    init(manufacturer: [UInt8]?) { self.manufacturer = manufacturer }
    func localName() -> String? { nil }
    func manufacturerData() -> [UInt8]? { manufacturer }
    func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [] }
    func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [] }
    func serviceData(_ uuid: BluetoothUUID) -> [UInt8]? { nil }
    func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [] }
    func txPowerLevel() -> Int32 { .min }
    func isConnectable() -> Int32 { -1 }
}
