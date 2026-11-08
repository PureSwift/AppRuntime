import Testing
import DynamicDevice
import DynamicRuntime

/// Pins the device contracts.
@Suite struct DynamicDeviceTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    @Test func noPermissions() {
        #expect(DeviceProxy.descriptor.capability == nil)
        #expect(method(DeviceProxy.descriptor, "current") == MethodDescriptor("current", "()O", .constructor))
        #expect(!DeviceProxy.descriptor.methods.contains { $0.key.lowercased().contains("authoriz") })
    }

    @Test(arguments: ["serial", "imei", "mac", "udid", "address"])
    func noHardwareIdentifier(_ word: String) {
        #expect(!DeviceProxy.descriptor.methods.contains { $0.key.lowercased().contains(word) })
    }

    @Test func properties() {
        let device = DeviceProxy.descriptor
        #expect(method(device, "vendorIdentifier")?.signature == Signature("()O"), "nullable")
        #expect(method(device, "batteryLevel")?.signature == Signature("()F"))
        #expect(method(device, "physicalMemory")?.signature == Signature("()J"))
        #expect(method(device, "apiLevel")?.signature == Signature("()I"))
        #expect(method(device, "setDelegate:")?.signature == Signature("(O)V"))
        #expect(method(DeviceDelegateProxy.descriptor, "didChangeBatteryLevel:level:")?.signature == Signature("(OF)V"))
        #expect(method(DeviceDelegateProxy.descriptor, "didChangeProximityState:near:")?.signature == Signature("(OZ)V"))
    }

    @Test func recordsRoundTrip() {
        let descriptors = [DeviceProxy.descriptor, DeviceDelegateProxy.descriptor]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    @Test func codes() {
        #expect(DeviceIdiom(rawValue: 6) == .desktop)
        #expect(ThermalState.critical.rawValue == 3)
        #expect(DeviceOrientation(rawValue: 5) == .faceUp)
    }
}
