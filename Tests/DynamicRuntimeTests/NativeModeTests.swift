import XCTest
import CRuntime
import DynamicRuntime
import ExampleApp
import ExampleContracts
import ExampleHost
import RuntimeCore
import RuntimeNative

/// The example app linked as a native slice: the host (this test) owns main,
/// registers the Swift implementations and calls `rt_main`.
final class NativeModeTests: XCTestCase {

    var native: NativeRuntime { NativeRuntime.shared }

    override func setUp() {
        ExampleHost.lines = []
        native.capabilities = nil
        ExampleHost.register(in: native)
    }

    func testExampleApp() {
        let handles = native.runtime.handleCount
        let status = native.start(rt_main)
        let lines = ExampleHost.lines
        XCTAssertEqual(status, .ok, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("FAIL") }, [])
        XCTAssertTrue(lines.contains("beacon available"))
        XCTAssertEqual(lines.last, "done")
        // Every proxy, export and temporary was released.
        XCTAssertEqual(native.runtime.handleCount, handles)
        XCTAssertEqual(Exported.liveCount, 0)
    }

    func testCapabilityGate() {
        native.capabilities = []
        XCTAssertEqual(Runtime.lookupClass("org.pureswift.example.Beacon"), 0)
        XCTAssertNotEqual(Runtime.lookupClass("org.pureswift.example.Counter"), 0)
        native.capabilities = [.bluetooth]
        XCTAssertNotEqual(Runtime.lookupClass("org.pureswift.example.Beacon"), 0)
    }

    func testHostRecoversItsOwnObject() {
        let delegate = RecordingDelegate()
        let counter = CounterProxy.make(start: 41, delegate: delegate)
        let host = native.swiftObject(for: counter) as? HostCounter
        XCTAssertEqual(host?.value(), 41)
        counter.increment(by: 1)
        XCTAssertEqual(delegate.values, [42])
        XCTAssertNil(native.swiftObject(for: RuntimeList.make()), "not an exported object")
    }

    func testMethodAddedInLaterVersionIsAbsent() {
        // A host that implements an older Counter without `reset`.
        let older = ContractDescriptor(
            name: CounterProxy.descriptor.name,
            kind: .contract,
            version: 1,
            methods: CounterProxy.descriptor.methods.filter { $0.key != "reset" }
        )
        native.register(older, statics: nil)
        defer { ExampleHost.register(in: native) }
        XCTAssertFalse(MethodReference(CounterProxy.classReference, "reset", "()V").isAvailable)
        XCTAssertTrue(MethodReference(CounterProxy.classReference, "value", "()J").isAvailable)
    }

    func testThrowingCallReportsNotFound() {
        // An unknown class: rt_call is never reached, the proxy throws.
        let missing = MethodReference(ClassReference("org.example.Missing"), "run", "()V")
        XCTAssertThrowsError(try Call(missing).invoke()) { error in
            XCTAssertEqual(error as? RuntimeError, .notFound)
        }
    }

    func testValidation() {
        let contracts = ExampleHost.contracts
        XCTAssertEqual(native.runtime.validate(abiVersion: runtimeABIVersion, contracts: contracts, capabilities: [.bluetooth]), [])
        let issues = native.runtime.validate(abiVersion: runtimeABIVersion, contracts: contracts, capabilities: [])
        XCTAssertEqual(issues.map(\.contract), ["org.pureswift.example.Beacon"])
    }

    func testMetadataSection() throws {
        // The macro placed one rt.contracts record per contract in this
        // binary; decode them from the descriptors' encoding.
        let records = ExampleHost.contracts.flatMap(ContractMetadata.encode)
        XCTAssertEqual(ContractMetadata.decode(records), ExampleHost.contracts)
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
