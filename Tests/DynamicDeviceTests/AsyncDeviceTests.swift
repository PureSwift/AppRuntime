import Testing
@testable import DynamicDevice
import DynamicRuntime
import RuntimeNative

// MARK: - Host fake

final class HostDevice: Device {

    nonisolated(unsafe) static let shared = HostDevice()

    var delegate: (any DeviceDelegate)?

    var battery = false

    var orientationUpdates = false

    var proximity = false

    static func current() -> HostDevice { shared }

    func setDelegate(_ delegate: (any DeviceDelegate)?) { self.delegate = delegate }
    func name() -> String { "Test" }
    func model() -> String { "Model" }
    func modelIdentifier() -> String { "Test1,1" }
    func manufacturer() -> String { "PureSwift" }
    func systemName() -> String { "TestOS" }
    func systemVersion() -> String { "1.0" }
    func apiLevel() -> Int32 { 0 }
    func idiom() -> Int32 { DeviceIdiom.phone.rawValue }
    func vendorIdentifier() -> String? { nil }
    func isSimulator() -> Bool { true }
    func physicalMemory() -> Int64 { 1 << 30 }
    func processorCount() -> Int32 { 4 }
    func uptime() -> Int64 { 0 }
    func setBatteryMonitoringEnabled(_ enabled: Bool) { battery = enabled }
    func batteryLevel() -> Float { 0.5 }
    func batteryState() -> Int32 { BatteryState.unplugged.rawValue }
    func isLowPowerModeEnabled() -> Bool { false }
    func thermalState() -> Int32 { ThermalState.nominal.rawValue }
    func setOrientationUpdatesEnabled(_ enabled: Bool) { orientationUpdates = enabled }
    func orientation() -> Int32 { DeviceOrientation.portrait.rawValue }
    func setProximityMonitoringEnabled(_ enabled: Bool) { proximity = enabled }
    func isProximityMonitoringEnabled() -> Bool { proximity }
    func proximityState() -> Bool { false }
}

// MARK: - Tests

/// `AsyncDevice` against a fake host, through the native runtime.
/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct AsyncDeviceTests {

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        DeviceProxy.register(HostDevice.self, in: native)
        DeviceDelegateProxy.registerInterface(in: native)
    }

    @Test func eventsTurnMonitoringOnAndOff() async throws {
        let host = HostDevice.shared
        let device = AsyncDevice()
        #expect(device.device.modelIdentifier() == "Test1,1")
        do {
            let events = device.events(battery: true, orientation: true)
            #expect(host.battery && host.orientationUpdates && !host.proximity)
            let delegate = try #require(host.delegate)
            delegate.didChangeBatteryLevel(host, level: 0.25)
            delegate.didChangeThermalState(host, state: ThermalState.serious.rawValue)
            delegate.didChangeOrientation(host, orientation: DeviceOrientation.landscapeLeft.rawValue)
            var received: [DeviceEvent] = []
            for await event in events {
                received.append(event)
                if received.count == 3 { break }
            }
            #expect(received == [.batteryLevel(0.25), .thermalState(.serious), .orientation(.landscapeLeft)])
        }
        #expect(!host.battery && !host.orientationUpdates)
        #expect(host.delegate == nil, "the delegate is removed with the stream")
    }
}
