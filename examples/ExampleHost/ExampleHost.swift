import DynamicRuntime
import ExampleContracts

/// Host side of the example: registers the Swift implementations.
public enum ExampleHost {

    /// Registers every example contract and callback interface.
    public static func register(in registrar: some ContractRegistrar) {
        CounterProxy.register(HostCounter.self, in: registrar)
        CounterDelegateProxy.registerInterface(in: registrar)
        ReporterProxy.register(HostReporter.self, in: registrar)
        BeaconProxy.register(HostBeacon.self, in: registrar)
    }

    /// Lines the app recorded through `Reporter`.
    nonisolated(unsafe) public static var lines: [String] = []

    /// Every contract the example app uses, as a slice's `rt.contracts`
    /// section would list them.
    public static var contracts: [ContractDescriptor] {
        [
            CounterProxy.descriptor,
            CounterDelegateProxy.descriptor,
            ReporterProxy.descriptor,
            BeaconProxy.descriptor,
        ]
    }
}
