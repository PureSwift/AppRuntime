#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A peripheral found by a scan.
public struct ScanResult: @unchecked Sendable {

    public let peripheral: any Peripheral

    public let advertisement: any Advertisement

    /// Signal strength in dBm.
    public let rssi: Int32
}

/// Async/await over `Central` (§6.2.1): the guest-side convenience layer.
///
/// It makes the `Central` with its own delegate and turns the callbacks into
/// async calls and `EventStream`s. Native hosts never see it. Permissions
/// still come first: `authorization` never prompts, and
/// `requestAuthorization()` is the only call that does.
///
/// ```swift
/// let central = AsyncCentral()
/// guard await central.requestAuthorization() == .allowed else { return }
/// try await central.waitUntilPoweredOn()
/// for try await result in central.scan(services: [.bit16(0x180D)]) {
///     let peripheral = try await central.connect(result.peripheral)
///     let services = try await peripheral.discoverServices()
///     break
/// }
/// ```
///
/// One scan at a time: starting a scan finishes the previous scan's stream.
/// The guest is single-threaded (§6.4).
public final class AsyncCentral: @unchecked Sendable {

    /// The underlying contract object, for calls without an async form.
    public let central: any Central

    let events: CentralEvents

    /// Makes a central. Doesn't prompt for permission.
    public init() {
        let events = CentralEvents()
        self.events = events
        self.central = CentralProxy.make(events)
    }

    /// Whether this host provides Bluetooth, with the capability granted.
    public static var isAvailable: Bool {
        CentralProxy.isAvailable
    }

    // MARK: Authorization and state

    /// The current authorization. Never prompts.
    public static var authorization: BluetoothAuthorization {
        BluetoothAuthorization(rawValue: CentralProxy.authorizationStatus()) ?? .notDetermined
    }

    /// Prompts for permission if it hasn't been decided, and returns the
    /// outcome. Returns the current authorization if the task is cancelled.
    public func requestAuthorization() async -> BluetoothAuthorization {
        let current = Self.authorization
        guard current == .notDetermined else { return current }
        return await withCallback { (callback: Callback<BluetoothAuthorization, Never>) in
            events.authorization.append(callback)
            central.requestAuthorization()
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
    }

    public var state: CentralState {
        CentralState(rawValue: central.state()) ?? .unknown
    }

    /// Returns once the radio is powered on. Throws `unauthorized` or
    /// `unsupported` if it never can be, and `operationCancelled` if the task
    /// is cancelled. Waits while it's off or still starting.
    public func waitUntilPoweredOn() async throws(BluetoothError) {
        if let result = Self.readiness(state) {
            return try result.get()
        }
        try await withCallback { (callback: Callback<Void, BluetoothError>) in
            events.poweredOn.append(callback)
        } onCancel: { callback in
            callback.resume(throwing: .operationCancelled)
        }
    }

    /// State changes, starting with the next one.
    public func states() -> EventStream<CentralState, Never> {
        let (stream, continuation) = EventStream<CentralState, Never>.makeStream()
        let id = events.states.add(continuation)
        continuation.onTermination = { [events] in
            events.states.remove(id)
        }
        return stream
    }

    /// Whether `state` settles `waitUntilPoweredOn`: success, failure, or
    /// `nil` to keep waiting.
    static func readiness(_ state: CentralState) -> Result<Void, BluetoothError>? {
        switch state {
        case .poweredOn:
            return .success(())
        case .unauthorized:
            return .failure(.unauthorized)
        case .unsupported:
            return .failure(.unsupported)
        case .unknown, .resetting, .poweredOff:
            return nil
        }
    }

    // MARK: Scanning

    /// Scans until the stream is released, its task is cancelled, or the
    /// host stops the scan; then stops scanning. Finishes by throwing if
    /// the scan fails or the radio turns off.
    ///
    /// - Parameter services: Only peripherals advertising one of these; all
    ///   peripherals if empty.
    public func scan(
        services: [BluetoothUUID] = [],
        allowDuplicates: Bool = false,
        mode: ScanMode = .balanced
    ) -> EventStream<ScanResult, BluetoothError> {
        let (stream, continuation) = EventStream<ScanResult, BluetoothError>.makeStream()
        events.scan?.finish()
        events.scanGeneration &+= 1
        let generation = events.scanGeneration
        events.scan = continuation
        continuation.onTermination = { [events, central] in
            guard events.scanGeneration == generation else { return }
            events.scan = nil
            central.stopScan()
        }
        central.scan(services: services, allowDuplicates: allowDuplicates, mode: mode.rawValue)
        return stream
    }

    // MARK: Connections

    /// Connects, and returns the peripheral ready for GATT calls.
    ///
    /// - Parameter timeout: Milliseconds; `0` waits until connected or cancelled.
    /// - Throws: The connection error, or `operationCancelled` if the task is
    ///   cancelled, which also cancels the connection attempt.
    public func connect(_ peripheral: any Peripheral, timeout: Int32 = 0) async throws(BluetoothError) -> AsyncPeripheral {
        try await withCallback { (callback: Callback<Void, BluetoothError>) in
            events.connections.append(callback, for: peripheral)
            central.connect(peripheral, timeout: timeout)
        } onCancel: { [central] callback in
            // Resume first: the host may report the cancelled attempt as a
            // disconnect before cancelConnection returns.
            callback.resume(throwing: .operationCancelled)
            central.cancelConnection(peripheral)
        }
        let connected = AsyncPeripheral(peripheral)
        events.connected.append(connected)
        return connected
    }

    /// Disconnects, and returns once the host reports it.
    public func disconnect(_ peripheral: AsyncPeripheral) async {
        await withCallback { (callback: Callback<Void, Never>) in
            events.disconnections.append(callback, for: peripheral.peripheral)
            central.cancelConnection(peripheral.peripheral)
        } onCancel: { callback in
            callback.resume()
        }
    }
}

/// The delegate behind `AsyncCentral`.
final class CentralEvents: CentralDelegate {

    let authorization = PendingCallbacks<BluetoothAuthorization, Never>()

    let poweredOn = PendingCallbacks<Void, BluetoothError>()

    let states = EventSubscribers<CentralState, Never>()

    var scan: EventStream<ScanResult, BluetoothError>.Continuation?

    var scanGeneration = 0

    let connections = PendingCallbacks<Void, BluetoothError>()

    let disconnections = PendingCallbacks<Void, Never>()

    /// Peripherals connected through `AsyncCentral.connect`, told when they
    /// disconnect.
    var connected: [AsyncPeripheral] = []

    func didChangeAuthorization(_ central: any Central, status: Int32) {
        let status = BluetoothAuthorization(rawValue: status) ?? .notDetermined
        guard status != .notDetermined else { return }
        authorization.resumeAll(with: .success(status))
    }

    func didUpdateState(_ central: any Central, state: Int32) {
        let state = CentralState(rawValue: state) ?? .unknown
        states.yield(state)
        if let result = AsyncCentral.readiness(state) {
            poweredOn.resumeAll(with: result)
        }
        switch state {
        case .poweredOff:
            scan?.finish(throwing: .poweredOff)
        case .unauthorized:
            scan?.finish(throwing: .unauthorized)
        case .unsupported:
            scan?.finish(throwing: .unsupported)
        case .unknown, .resetting, .poweredOn:
            break
        }
    }

    func didDiscover(_ central: any Central, peripheral: any Peripheral, advertisement: any Advertisement, rssi: Int32) {
        scan?.yield(ScanResult(peripheral: peripheral, advertisement: advertisement, rssi: rssi))
    }

    func didStopScanning(_ central: any Central, error: Int32) {
        scan?.finish(throwing: BluetoothError(code: error))
    }

    func didConnect(_ central: any Central, peripheral: any Peripheral) {
        connections.resume(for: peripheral, with: .success(()))
    }

    func didFailToConnect(_ central: any Central, peripheral: any Peripheral, error: Int32) {
        connections.resume(for: peripheral, with: .failure(BluetoothError(code: error) ?? .connectionFailed))
    }

    func didDisconnect(_ central: any Central, peripheral: any Peripheral, error: Int32) {
        // A disconnect while connecting fails the connection attempt.
        connections.resume(for: peripheral, with: .failure(BluetoothError(code: error) ?? .peripheralDisconnected))
        while disconnections.resume(for: peripheral, with: .success(())) { }
        let reason = BluetoothError(code: error) ?? .peripheralDisconnected
        var remaining: [AsyncPeripheral] = []
        for connected in connected {
            if DynamicObject.same(connected.peripheral, peripheral) {
                connected.events.disconnected(reason)
            } else {
                remaining.append(connected)
            }
        }
        connected = remaining
    }
}
#endif
