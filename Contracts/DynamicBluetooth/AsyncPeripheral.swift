#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Async/await over a connected `Peripheral`'s GATT calls (§6.2.1).
/// `AsyncCentral.connect` returns one.
///
/// It sets itself as the peripheral's delegate. Requests about the same
/// attribute complete in order. Cancelling a task can't cancel the native
/// request: the call throws `operationCancelled` at once, and the native
/// result is discarded when it arrives. When the peripheral disconnects,
/// pending calls throw the disconnect reason and notification streams
/// finish with it.
public final class AsyncPeripheral: @unchecked Sendable {

    /// The underlying contract object, for calls without an async form.
    public let peripheral: any Peripheral

    let events: PeripheralEvents

    init(_ peripheral: any Peripheral) {
        let events = PeripheralEvents()
        self.peripheral = peripheral
        self.events = events
        peripheral.setDelegate(events)
    }

    deinit {
        peripheral.setDelegate(nil)
    }

    /// The platform's stable identifier (never a MAC address on iOS).
    public var identifier: String {
        peripheral.identifier()
    }

    public var name: String? {
        peripheral.name()
    }

    public var state: PeripheralState {
        PeripheralState(rawValue: peripheral.state()) ?? .disconnected
    }

    // MARK: Discovery

    /// Discovers services; all of them if `uuids` is empty.
    public func discoverServices(_ uuids: [BluetoothUUID] = []) async throws(BluetoothError) -> [any Service] {
        try await request { (callback: Callback<Void, BluetoothError>) in
            events.services.append(callback)
            peripheral.discoverServices(uuids)
        }
        return peripheral.services()
    }

    /// Discovers a service's characteristics; all of them if `uuids` is empty.
    public func discoverCharacteristics(_ uuids: [BluetoothUUID] = [], for service: any Service) async throws(BluetoothError) -> [any Characteristic] {
        try await request { callback in
            events.characteristics.append(callback, for: service)
            peripheral.discoverCharacteristics(uuids, for: service)
        }
        return service.characteristics()
    }

    public func discoverDescriptors(for characteristic: any Characteristic) async throws(BluetoothError) -> [any Descriptor] {
        try await request { callback in
            events.descriptors.append(callback, for: characteristic)
            peripheral.discoverDescriptors(for: characteristic)
        }
        return characteristic.descriptors()
    }

    // MARK: Characteristics

    /// Reads a characteristic's value.
    public func read(_ characteristic: any Characteristic) async throws(BluetoothError) -> [UInt8] {
        try await request { callback in
            events.reads.append(callback, for: characteristic)
            peripheral.readValue(characteristic)
        }
    }

    /// Writes a characteristic's value. With `withResponse` it returns when
    /// the peripheral acknowledges the write; `withoutResponse` waits until
    /// the host can queue the write, then returns.
    public func write(_ value: [UInt8], to characteristic: any Characteristic, type: WriteType = .withResponse) async throws(BluetoothError) {
        switch type {
        case .withResponse:
            try await request { callback in
                events.writes.append(callback, for: characteristic)
                peripheral.writeValue(value, for: characteristic, type: type.rawValue)
            }
        case .withoutResponse:
            if !peripheral.canSendWriteWithoutResponse() {
                try await request { callback in
                    events.readyToWrite.append(callback)
                }
            }
            peripheral.writeValue(value, for: characteristic, type: type.rawValue)
        }
    }

    /// The largest value one write of `type` can carry.
    public func maximumWriteLength(_ type: WriteType = .withResponse) -> Int {
        Int(peripheral.maximumWriteLength(type.rawValue))
    }

    /// Subscribes to a characteristic's notifications or indications.
    /// Values arrive until the stream is released or its task is cancelled,
    /// which unsubscribes; the stream finishes by throwing if subscribing
    /// fails or the peripheral disconnects.
    public func notifications(for characteristic: any Characteristic) -> EventStream<[UInt8], BluetoothError> {
        let (stream, continuation) = EventStream<[UInt8], BluetoothError>.makeStream()
        let id = events.notifications.add(continuation, for: characteristic)
        continuation.onTermination = { [events, peripheral] in
            events.notifications.remove(id)
            if !events.isDisconnected, !events.notifications.contains(characteristic) {
                peripheral.setNotifyValue(false, for: characteristic)
            }
        }
        peripheral.setNotifyValue(true, for: characteristic)
        return stream
    }

    // MARK: Descriptors

    public func read(_ descriptor: any Descriptor) async throws(BluetoothError) -> [UInt8] {
        try await request { callback in
            events.descriptorReads.append(callback, for: descriptor)
            peripheral.readDescriptor(descriptor)
        }
    }

    public func write(_ value: [UInt8], to descriptor: any Descriptor) async throws(BluetoothError) {
        try await request { callback in
            events.descriptorWrites.append(callback, for: descriptor)
            peripheral.writeDescriptor(value, for: descriptor)
        }
    }

    // MARK: Signal

    /// Reads the connection's signal strength in dBm.
    public func readRSSI() async throws(BluetoothError) -> Int32 {
        try await request { callback in
            events.rssi.append(callback)
            peripheral.readRSSI()
        }
    }

    // MARK: Requests

    /// One GATT request: fails at once if disconnected, and throws
    /// `operationCancelled` if its task is cancelled.
    private func request<Value>(
        _ start: (Callback<Value, BluetoothError>) -> Void
    ) async throws(BluetoothError) -> Value {
        if let reason = events.disconnectReason {
            throw reason
        }
        return try await withCallback(start) { callback in
            callback.resume(throwing: .operationCancelled)
        }
    }
}

/// The delegate behind `AsyncPeripheral`.
final class PeripheralEvents: PeripheralDelegate {

    let services = PendingCallbacks<Void, BluetoothError>()

    let characteristics = PendingCallbacks<Void, BluetoothError>()

    let descriptors = PendingCallbacks<Void, BluetoothError>()

    let reads = PendingCallbacks<[UInt8], BluetoothError>()

    let writes = PendingCallbacks<Void, BluetoothError>()

    let readyToWrite = PendingCallbacks<Void, BluetoothError>()

    let descriptorReads = PendingCallbacks<[UInt8], BluetoothError>()

    let descriptorWrites = PendingCallbacks<Void, BluetoothError>()

    let rssi = PendingCallbacks<Int32, BluetoothError>()

    let notifications = EventSubscribers<[UInt8], BluetoothError>()

    /// Set once the peripheral disconnects.
    var disconnectReason: BluetoothError?

    var isDisconnected: Bool {
        disconnectReason != nil
    }

    func disconnected(_ reason: BluetoothError) {
        guard disconnectReason == nil else { return }
        disconnectReason = reason
        services.failAll(reason)
        characteristics.failAll(reason)
        descriptors.failAll(reason)
        reads.failAll(reason)
        writes.failAll(reason)
        readyToWrite.failAll(reason)
        descriptorReads.failAll(reason)
        descriptorWrites.failAll(reason)
        rssi.failAll(reason)
        notifications.finishAll(throwing: reason)
    }

    private static func result(_ error: Int32) -> Result<Void, BluetoothError> {
        BluetoothError(code: error).map { .failure($0) } ?? .success(())
    }

    func didDiscoverServices(_ peripheral: any Peripheral, error: Int32) {
        services.resume(with: Self.result(error))
    }

    func didDiscoverCharacteristics(_ peripheral: any Peripheral, service: any Service, error: Int32) {
        characteristics.resume(for: service, with: Self.result(error))
    }

    func didDiscoverDescriptors(_ peripheral: any Peripheral, characteristic: any Characteristic, error: Int32) {
        descriptors.resume(for: characteristic, with: Self.result(error))
    }

    func didUpdateValue(_ peripheral: any Peripheral, characteristic: any Characteristic, value: [UInt8], error: Int32) {
        // A read's reply and a notification arrive the same way: the value
        // answers the oldest read, and every subscriber sees it.
        let error = BluetoothError(code: error)
        reads.resume(for: characteristic, with: error.map { .failure($0) } ?? .success(value))
        if error == nil {
            notifications.yield(value, for: characteristic)
        }
    }

    func didWriteValue(_ peripheral: any Peripheral, characteristic: any Characteristic, error: Int32) {
        writes.resume(for: characteristic, with: Self.result(error))
    }

    func didUpdateNotificationState(_ peripheral: any Peripheral, characteristic: any Characteristic, error: Int32) {
        if let error = BluetoothError(code: error) {
            notifications.finish(for: characteristic, throwing: error)
        }
    }

    func didUpdateDescriptorValue(_ peripheral: any Peripheral, descriptor: any Descriptor, value: [UInt8], error: Int32) {
        descriptorReads.resume(for: descriptor, with: BluetoothError(code: error).map { .failure($0) } ?? .success(value))
    }

    func didWriteDescriptorValue(_ peripheral: any Peripheral, descriptor: any Descriptor, error: Int32) {
        descriptorWrites.resume(for: descriptor, with: Self.result(error))
    }

    func didReadRSSI(_ peripheral: any Peripheral, rssi: Int32, error: Int32) {
        self.rssi.resume(with: BluetoothError(code: error).map { .failure($0) } ?? .success(rssi))
    }

    func isReadyToSendWriteWithoutResponse(_ peripheral: any Peripheral) {
        readyToWrite.resumeAll(with: .success(()))
    }

    func didModifyServices(_ peripheral: any Peripheral) { }

    func didUpdateName(_ peripheral: any Peripheral) { }
}
#endif
