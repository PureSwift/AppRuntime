import Testing
@testable import DynamicBluetooth
import DynamicRuntime
import RuntimeNative

// MARK: - Host fakes
//
// A Swift-registry host's Bluetooth implementation, answering every request
// at once unless told to hold it.

final class HostCentral: Central {

    nonisolated(unsafe) static var status = BluetoothAuthorization.notDetermined.rawValue

    nonisolated(unsafe) static var last: HostCentral?

    let delegate: any CentralDelegate

    var stateValue = CentralState.poweredOn.rawValue

    var scanning = false

    var scannedServices: [BluetoothUUID] = []

    /// Connections the fake holds instead of answering.
    var holdConnections = false

    var heldConnections: [any Peripheral] = []

    var connectionError: Int32 = 0

    var cancelledConnections = 0

    init(delegate: any CentralDelegate) {
        self.delegate = delegate
    }

    static func authorizationStatus() -> Int32 { status }

    static func make(_ delegate: any CentralDelegate) -> HostCentral {
        let central = HostCentral(delegate: delegate)
        last = central
        return central
    }

    func requestAuthorization() {
        Self.status = BluetoothAuthorization.allowed.rawValue
        delegate.didChangeAuthorization(self, status: Self.status)
    }

    func state() -> Int32 { stateValue }

    func setState(_ state: CentralState) {
        stateValue = state.rawValue
        delegate.didUpdateState(self, state: state.rawValue)
    }

    func scan(services: [BluetoothUUID], allowDuplicates: Bool, mode: Int32) {
        scanning = true
        scannedServices = services
    }

    func stopScan() { scanning = false }

    func isScanning() -> Bool { scanning }

    func discover(_ peripheral: HostPeripheral, rssi: Int32 = -50) {
        delegate.didDiscover(self, peripheral: peripheral, advertisement: HostAdvertisement(), rssi: rssi)
    }

    func connect(_ peripheral: any Peripheral, timeout: Int32) {
        if holdConnections {
            heldConnections.append(peripheral)
        } else if connectionError != 0 {
            delegate.didFailToConnect(self, peripheral: peripheral, error: connectionError)
        } else {
            delegate.didConnect(self, peripheral: peripheral)
        }
    }

    func cancelConnection(_ peripheral: any Peripheral) {
        cancelledConnections += 1
        heldConnections.removeAll()
        delegate.didDisconnect(self, peripheral: peripheral, error: 0)
    }

    func retrievePeripherals(_ identifiers: [String]) -> [any Peripheral] { [] }

    func retrieveConnectedPeripherals(_ services: [BluetoothUUID]) -> [any Peripheral] { [] }
}

final class HostAdvertisement: Advertisement {
    func localName() -> String? { "Fake" }
    func manufacturerData() -> [UInt8]? { nil }
    func serviceUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [.bit16(0x180D)] }
    func serviceDataUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [] }
    func serviceData(_ uuid: BluetoothUUID) -> [UInt8]? { nil }
    func solicitedServiceUUIDs() throws(RuntimeError) -> [BluetoothUUID] { [] }
    func txPowerLevel() -> Int32 { 0 }
    func isConnectable() -> Int32 { 1 }
}

final class HostService: Service {
    let uuidValue: BluetoothUUID
    var characteristicList: [HostCharacteristic] = []
    unowned(unsafe) let owner: HostPeripheral
    init(_ uuid: BluetoothUUID, owner: HostPeripheral) {
        self.uuidValue = uuid
        self.owner = owner
    }
    func uuid() throws(RuntimeError) -> BluetoothUUID { uuidValue }
    func isPrimary() -> Bool { true }
    func characteristics() -> [any Characteristic] { characteristicList }
    func peripheral() -> any Peripheral { owner }
}

final class HostCharacteristic: Characteristic {
    let uuidValue: BluetoothUUID
    var descriptorList: [HostDescriptor] = []
    var notifying = false
    unowned(unsafe) let owner: HostService
    init(_ uuid: BluetoothUUID, owner: HostService) {
        self.uuidValue = uuid
        self.owner = owner
    }
    func uuid() throws(RuntimeError) -> BluetoothUUID { uuidValue }
    func properties() -> Int32 { 0x1A }
    func value() -> [UInt8]? { nil }
    func isNotifying() -> Bool { notifying }
    func descriptors() -> [any Descriptor] { descriptorList }
    func service() -> any Service { owner }
}

final class HostDescriptor: Descriptor {
    unowned(unsafe) let owner: HostCharacteristic
    init(owner: HostCharacteristic) { self.owner = owner }
    func uuid() throws(RuntimeError) -> BluetoothUUID { .bit16(0x2902) }
    func value() -> [UInt8]? { nil }
    func characteristic() -> any Characteristic { owner }
}

final class HostPeripheral: Peripheral {

    let id: String

    var delegate: (any PeripheralDelegate)?

    var serviceList: [HostService] = []

    var written: [[UInt8]] = []

    var notifyChanges: [Bool] = []

    var readError: Int32 = 0

    init(_ id: String) {
        self.id = id
        let service = HostService(.bit16(0x180D), owner: self)
        let characteristic = HostCharacteristic(.bit16(0x2A37), owner: service)
        characteristic.descriptorList = [HostDescriptor(owner: characteristic)]
        service.characteristicList = [characteristic]
        serviceList = [service]
    }

    var characteristic: HostCharacteristic { serviceList[0].characteristicList[0] }

    func identifier() -> String { id }
    func name() -> String? { "Fake \(id)" }
    func state() -> Int32 { PeripheralState.connected.rawValue }
    func setDelegate(_ delegate: (any PeripheralDelegate)?) { self.delegate = delegate }
    func discoverServices(_ uuids: [BluetoothUUID]) { delegate?.didDiscoverServices(self, error: 0) }
    func services() -> [any Service] { serviceList }
    func discoverCharacteristics(_ uuids: [BluetoothUUID], for service: any Service) {
        delegate?.didDiscoverCharacteristics(self, service: service, error: 0)
    }
    func discoverDescriptors(for characteristic: any Characteristic) {
        delegate?.didDiscoverDescriptors(self, characteristic: characteristic, error: 0)
    }
    func readValue(_ characteristic: any Characteristic) {
        delegate?.didUpdateValue(self, characteristic: characteristic, value: readError == 0 ? [0x2A] : [], error: readError)
    }
    func writeValue(_ value: [UInt8], for characteristic: any Characteristic, type: Int32) {
        written.append(value)
        if type == WriteType.withResponse.rawValue {
            delegate?.didWriteValue(self, characteristic: characteristic, error: 0)
        }
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: any Characteristic) {
        notifyChanges.append(enabled)
        delegate?.didUpdateNotificationState(self, characteristic: characteristic, error: 0)
    }
    func readDescriptor(_ descriptor: any Descriptor) {
        delegate?.didUpdateDescriptorValue(self, descriptor: descriptor, value: [1, 0], error: 0)
    }
    func writeDescriptor(_ value: [UInt8], for descriptor: any Descriptor) {
        delegate?.didWriteDescriptorValue(self, descriptor: descriptor, error: 0)
    }
    func readRSSI() { delegate?.didReadRSSI(self, rssi: -40, error: 0) }
    func maximumWriteLength(_ type: Int32) -> Int32 { 20 }
    func canSendWriteWithoutResponse() -> Bool { true }

    func notify(_ value: [UInt8]) {
        delegate?.didUpdateValue(self, characteristic: characteristic, value: value, error: 0)
    }
}

// MARK: - Tests

/// `AsyncCentral` and `AsyncPeripheral` against a fake host, through the
/// native runtime: proxies, marshaling and `rt_same` are real.
///
/// Serialized: every test shares `NativeRuntime.shared`. Each test runs the
/// guest calls and the fake host's callbacks on its own task.
@Suite(.serialized) struct AsyncCentralTests {

    var native: NativeRuntime { NativeRuntime.shared }

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        CentralProxy.register(HostCentral.self, in: native)
        CentralDelegateProxy.registerInterface(in: native)
        PeripheralProxy.register(HostPeripheral.self, in: native)
        PeripheralDelegateProxy.registerInterface(in: native)
        ServiceProxy.register(HostService.self, in: native)
        CharacteristicProxy.register(HostCharacteristic.self, in: native)
        DescriptorProxy.register(HostDescriptor.self, in: native)
        AdvertisementProxy.register(HostAdvertisement.self, in: native)
        HostCentral.status = BluetoothAuthorization.notDetermined.rawValue
        // Release the previous test's central before anything is counted.
        HostCentral.last = nil
    }

    /// Scans for one peripheral and connects to it.
    func connected(_ central: AsyncCentral, _ fake: HostPeripheral) async throws -> AsyncPeripheral {
        let scan = central.scan()
        HostCentral.last?.discover(fake)
        var iterator = scan.makeAsyncIterator()
        let result = try #require(try await iterator.next())
        return try await central.connect(result.peripheral)
    }

    @Test func authorizationPromptsOnce() async {
        #expect(AsyncCentral.authorization == .notDetermined)
        let central = AsyncCentral()
        #expect(await central.requestAuthorization() == .allowed)
        #expect(AsyncCentral.authorization == .allowed)
        #expect(await central.requestAuthorization() == .allowed, "already decided: no prompt")
    }

    @Test func waitsUntilPoweredOn() async throws {
        let central = AsyncCentral()
        let fake = try #require(HostCentral.last)
        try await central.waitUntilPoweredOn()

        fake.stateValue = CentralState.poweredOff.rawValue
        let wait = Task { try await central.waitUntilPoweredOn() }
        while central.events.poweredOn.isEmpty {
            await Task.yield()
        }
        fake.setState(.poweredOn)
        try await wait.value

        fake.stateValue = CentralState.unsupported.rawValue
        await #expect(throws: BluetoothError.unsupported) {
            try await central.waitUntilPoweredOn()
        }
    }

    @Test func scanYieldsResultsThenStopsAndReleasesEverything() async throws {
        let handles = native.runtime.handleCount
        do {
            let central = AsyncCentral()
            let fake = try #require(HostCentral.last)
            do {
                let scan = central.scan(services: [.bit16(0x180D)])
                #expect(fake.scanning)
                #expect(fake.scannedServices == [.bit16(0x180D)])
                fake.discover(HostPeripheral("A"), rssi: -60)
                fake.discover(HostPeripheral("B"), rssi: -70)
                var found: [String] = []
                for try await result in scan {
                    found.append(result.peripheral.identifier() + " \(result.rssi)")
                    if found.count == 2 { break }
                }
                #expect(found == ["A -60", "B -70"])
                #expect(fake.scanning, "the stream is still alive")
            }
            #expect(!fake.scanning, "releasing the stream stops the scan")
        }
        // The fake host keeps its last central; let it go too.
        HostCentral.last = nil
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0)
    }

    @Test func scanFinishesWithTheHostsError() async throws {
        let central = AsyncCentral()
        let fake = try #require(HostCentral.last)
        let scan = central.scan()
        fake.discover(HostPeripheral("A"))
        fake.delegate.didStopScanning(fake, error: BluetoothError.scanThrottled.rawValue)
        var iterator = scan.makeAsyncIterator()
        #expect(try await iterator.next()?.peripheral.identifier() == "A")
        await #expect(throws: BluetoothError.scanThrottled) {
            _ = try await iterator.next()
        }

        // A new scan replaces the old one; the radio turning off ends it.
        let second = central.scan()
        fake.setState(.poweredOff)
        await #expect(throws: BluetoothError.poweredOff) {
            for try await _ in second { }
        }
    }

    @Test func gattCalls() async throws {
        let handles = native.runtime.handleCount
        do {
            let central = AsyncCentral()
            let fake = HostPeripheral("A")
            let peripheral = try await connected(central, fake)
            #expect(peripheral.identifier == "A")

            let services = try await peripheral.discoverServices()
            #expect(try services.map { try $0.uuid() } == [.bit16(0x180D)])
            let characteristics = try await peripheral.discoverCharacteristics(for: services[0])
            let characteristic = try #require(characteristics.first)
            #expect(try characteristic.uuid() == .bit16(0x2A37))
            #expect(try await peripheral.discoverDescriptors(for: characteristic).count == 1)

            #expect(try await peripheral.read(characteristic) == [0x2A])
            try await peripheral.write([1, 2], to: characteristic)
            try await peripheral.write([3], to: characteristic, type: .withoutResponse)
            #expect(fake.written == [[1, 2], [3]])
            #expect(peripheral.maximumWriteLength() == 20)

            let descriptor = try #require(characteristic.descriptors().first)
            #expect(try await peripheral.read(descriptor) == [1, 0])
            try await peripheral.write([1, 0], to: descriptor)
            #expect(try await peripheral.readRSSI() == -40)

            fake.readError = BluetoothError.attribute.rawValue + 5
            await #expect(throws: BluetoothError.attribute) {
                _ = try await peripheral.read(characteristic)
            }

            await central.disconnect(peripheral)
            #expect(HostCentral.last?.cancelledConnections == 1)
            await #expect(throws: BluetoothError.peripheralDisconnected) {
                _ = try await peripheral.readRSSI()
            }
        }
        // The fake host keeps its last central; let it go too.
        HostCentral.last = nil
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0)
    }

    @Test func notificationsSubscribeAndUnsubscribe() async throws {
        let central = AsyncCentral()
        let fake = HostPeripheral("A")
        let peripheral = try await connected(central, fake)
        let characteristic = try #require(try await peripheral.discoverCharacteristics(for: peripheral.discoverServices()[0]).first)
        do {
            let values = peripheral.notifications(for: characteristic)
            #expect(fake.notifyChanges == [true])
            fake.notify([1])
            fake.notify([2])
            var received: [[UInt8]] = []
            for try await value in values {
                received.append(value)
                if received.count == 2 { break }
            }
            #expect(received == [[1], [2]])
        }
        #expect(fake.notifyChanges == [true, false], "releasing the stream unsubscribes")

        // A disconnect ends the stream with the reason.
        let values = peripheral.notifications(for: characteristic)
        HostCentral.last?.delegate.didDisconnect(HostCentral.last!, peripheral: fake, error: BluetoothError.connectionTimeout.rawValue)
        await #expect(throws: BluetoothError.connectionTimeout) {
            for try await _ in values { }
        }
    }

    @Test func connectFailsAndCancels() async throws {
        let central = AsyncCentral()
        let fake = try #require(HostCentral.last)
        let scan = central.scan()
        fake.discover(HostPeripheral("A"))
        var iterator = scan.makeAsyncIterator()
        let result = try #require(try await iterator.next())

        fake.connectionError = BluetoothError.connectionFailed.rawValue
        await #expect(throws: BluetoothError.connectionFailed) {
            _ = try await central.connect(result.peripheral)
        }

        fake.connectionError = 0
        fake.holdConnections = true
        let peripheral = result.peripheral
        let attempt = Task { _ = try await central.connect(peripheral) }
        while fake.heldConnections.isEmpty {
            await Task.yield()
        }
        attempt.cancel()
        await #expect(throws: BluetoothError.operationCancelled) {
            try await attempt.value
        }
        #expect(fake.cancelledConnections == 1, "cancelling the task cancels the attempt")
    }
}
