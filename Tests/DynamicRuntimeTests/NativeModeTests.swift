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

    // MARK: Clock and executor

    @Test func clockTimerThroughTheRuntime() throws {
        let clock = ManualClock()
        native.runtime.clock = clock
        defer { native.runtime.clock = nil }
        let handles = native.runtime.handleCount
        var fired = 0
        try RuntimeClock.after(nanoseconds: 500) { fired += 1 }
        #expect(Exported.liveCount == 1, "the timer's ClockDelegate")
        clock.advance(by: 499)
        #expect(fired == 0)
        clock.advance(by: 1)
        #expect(fired == 1)
        #expect(Exported.liveCount == 0, "the host released the delegate after firing")
        #expect(native.runtime.handleCount == handles)
        #expect(try RuntimeClock.now() == 500)
    }

    @Test func clockWithoutAHostClockThrows() {
        native.runtime.clock = nil
        #expect(throws: RuntimeError.thrown("This host has no clock")) {
            _ = try RuntimeClock.now()
        }
        #expect(throws: RuntimeError.thrown("This host has no clock")) {
            try RuntimeClock.after(nanoseconds: 1) { }
        }
        #expect(Exported.liveCount == 0, "the refused timer's export was finalized")
    }

    @Test func executorEntryOutsideEmbedded() {
        // Swift's own executor runs jobs here, so entering only runs the body.
        #expect(GuestExecutor.enter { 42 } == 42)
        #expect(GuestExecutor.pendingCount == 0)
        #expect(Runtime.main { .thrown }.rawValue == RuntimeStatus.thrown.rawValue)
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
