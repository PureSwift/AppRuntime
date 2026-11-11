import Testing
import CRuntime
import DynamicRuntime
import ExampleApp
import ExampleContracts
import ExampleHost
import RuntimeCore
import RuntimeNative

/// The example app linked as a native slice: the host (this test) owns main,
/// registers the Swift implementations and calls `rt_main`.
///
/// Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct NativeModeTests {

    var native: NativeRuntime { NativeRuntime.shared }

    init() {
        ExampleHost.lines = []
        native.capabilities = nil
        ExampleHost.register(in: native)
    }

    @Test func exampleApp() {
        let handles = native.runtime.handleCount
        let status = native.start(rt_main)
        let lines = ExampleHost.lines
        #expect(status == .ok, "\(lines.joined(separator: "\n"))")
        #expect(lines.filter { $0.hasPrefix("FAIL") } == [])
        #expect(lines.contains("beacon available"))
        #expect(lines.last == "done")
        // Every proxy, export and temporary was released.
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0)
    }

    @Test func capabilityGate() {
        native.capabilities = []
        #expect(Runtime.lookupClass("org.pureswift.example.Beacon") == 0)
        #expect(Runtime.lookupClass("org.pureswift.example.Counter") != 0)
        native.capabilities = [.bluetooth]
        #expect(Runtime.lookupClass("org.pureswift.example.Beacon") != 0)
    }

    @Test func hostRecoversItsOwnObject() {
        let delegate = RecordingDelegate()
        let counter = CounterProxy.make(start: 41, delegate: delegate)
        let host = native.swiftObject(for: counter) as? HostCounter
        #expect(host?.value() == 41)
        counter.increment(by: 1)
        #expect(delegate.values == [42])
        #expect(native.swiftObject(for: RuntimeList.make()) == nil, "not an exported object")
    }

    @Test func methodAddedInLaterVersionIsAbsent() {
        // A host that implements an older Counter without `reset`.
        let older = ContractDescriptor(
            name: CounterProxy.descriptor.name,
            kind: .contract,
            version: 1,
            methods: CounterProxy.descriptor.methods.filter { $0.key != "reset" }
        )
        native.register(older, statics: nil)
        defer { ExampleHost.register(in: native) }
        #expect(!MethodReference(CounterProxy.classReference, "reset", "()V").isAvailable)
        #expect(MethodReference(CounterProxy.classReference, "value", "()J").isAvailable)
    }

    @Test func throwingCallReportsNotFound() {
        // An unknown class: rt_call is never reached, the proxy throws.
        let missing = MethodReference(ClassReference("org.example.Missing"), "run", "()V")
        #expect(throws: RuntimeError.notFound) {
            _ = try Call(missing).invoke()
        }
    }

    @Test func validation() {
        let contracts = ExampleHost.contracts
        #expect(native.runtime.validate(abiVersion: runtimeABIVersion, contracts: contracts, capabilities: [.bluetooth]) == [])
        let issues = native.runtime.validate(abiVersion: runtimeABIVersion, contracts: contracts, capabilities: [])
        #expect(issues.map(\.contract) == ["org.pureswift.example.Beacon"])
    }

    @Test func metadataSection() throws {
        // The macro placed one rt.contracts record per contract in this
        // binary; decode them from the descriptors' encoding.
        let records = ExampleHost.contracts.flatMap(ContractMetadata.encode)
        #expect(ContractMetadata.decode(records) == ExampleHost.contracts)
    }
}

final class RecordingDelegate: CounterDelegate {

    var values: [Int64] = []

    func didChange(_ counter: any Counter, value: Int64) {
        values.append(value)
    }

    func shouldIncrement(_ counter: any Counter, by amount: Int32) -> Bool {
        true
    }

    func didReset(_ counter: any Counter) { }
}
