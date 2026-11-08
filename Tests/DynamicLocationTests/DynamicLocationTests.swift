import Testing
import DynamicLocation
import DynamicRuntime

/// Pins the location contracts.
@Suite struct DynamicLocationTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    static let descriptors = [
        LocationManagerProxy.descriptor, LocationManagerDelegateProxy.descriptor,
        LocationProxy.descriptor, HeadingProxy.descriptor,
    ]

    @Test(arguments: ["authorizationStatus", "accuracyAuthorization"])
    func statusNeverNeedsAnInstance(_ key: String) {
        #expect(method(LocationManagerProxy.descriptor, key) == MethodDescriptor(key, "()I", .static))
    }

    @Test func permissionsFirst() {
        let manager = LocationManagerProxy.descriptor
        #expect(manager.capability == .location)
        #expect(method(manager, "isLocationServicesEnabled")?.kind == .static)
        #expect(method(manager, "make:")?.kind == .constructor)
        // Two steps: foreground first, then background; precise on demand.
        #expect(method(manager, "requestWhenInUseAuthorization") != nil)
        #expect(method(manager, "requestAlwaysAuthorization") != nil)
        #expect(method(manager, "requestFullAccuracy:")?.signature == Signature("(O)V"))
        #expect(method(LocationManagerDelegateProxy.descriptor, "didChangeAuthorization:status:accuracy:")?.signature == Signature("(OII)V"))
    }

    @Test func updates() {
        let manager = LocationManagerProxy.descriptor
        #expect(method(manager, "setDesiredAccuracy:")?.signature == Signature("(I)V"), "accuracy tiers, not meters")
        #expect(method(manager, "lastLocation")?.signature == Signature("()O"))
        #expect(method(LocationProxy.descriptor, "timestamp")?.signature == Signature("()J"))
        #expect(method(LocationProxy.descriptor, "isSimulated")?.signature == Signature("()I"))
        #expect(method(HeadingProxy.descriptor, "trueHeading")?.signature == Signature("()D"))
        #expect(method(LocationManagerDelegateProxy.descriptor, "didUpdateLocations:locations:")?.signature == Signature("(OO)V"))
    }

    @Test func recordsRoundTrip() {
        #expect(ContractMetadata.decode(Self.descriptors.flatMap(ContractMetadata.encode)) == Self.descriptors)
    }

    @Test func codes() {
        #expect(LocationAuthorization(rawValue: 4) == .authorizedWhenInUse)
        #expect(LocationAccuracy.reduced.rawValue == 4)
    }
}
