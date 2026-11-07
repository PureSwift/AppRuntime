import XCTest
import RuntimeABI
@testable import RuntimeCore

/// A guest that records dispatches and finalizations.
final class FakeGuest: Guest {

    var capabilities: Set<Capability>?

    var dispatched: [(context: ContextID, index: UInt32, arguments: [Slot])] = []

    var finalized: [ContextID] = []

    var reply: (UInt32, [Slot]) -> (RuntimeStatus, Slot) = { _, _ in (.ok, 0) }

    init(capabilities: Set<Capability>? = nil) {
        self.capabilities = capabilities
    }

    func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        dispatched.append((context, index, Array(arguments)))
        let (status, value) = reply(index, Array(arguments))
        if !results.isEmpty {
            results[0] = value
        }
        return status
    }

    func finalize(context: ContextID) {
        finalized.append(context)
    }
}

final class HostRuntimeTests: XCTestCase {

    static let adder = ContractDescriptor(
        name: "org.example.Adder",
        kind: .contract,
        version: 2,
        capability: .bluetooth,
        methods: [
            MethodDescriptor("add:to:", "(II)I", .static),
            MethodDescriptor("make", "()O", .constructor),
            MethodDescriptor("value", "()I"),
        ]
    )

    static let listener = ContractDescriptor(
        name: "org.example.Listener",
        kind: .callback,
        methods: [MethodDescriptor("heard:", "(I)Z")]
    )

    var runtime: HostRuntime!

    var guest: FakeGuest!

    override func setUp() {
        runtime = HostRuntime()
        guest = FakeGuest()
        runtime.register(Self.adder) { index, arguments, results throws(RuntimeError) in
            switch index {
            case 0:
                results[0] = (Int32(slot: arguments[0]) + Int32(slot: arguments[1])).slot
            default:
                throw RuntimeError.thrown("no constructor here")
            }
        }
        runtime.register(Self.listener)
    }

    func lookup(_ name: String, guest: Guest? = nil) -> ClassID {
        runtime.lookupClass(Array(name.utf8), guest: guest ?? self.guest)
    }

    func method(_ cls: ClassID, _ key: String, _ signature: String, _ kind: MethodKind) -> MethodID {
        runtime.lookupMethod(cls, key: Array(key.utf8), signature: Array(signature.utf8), flags: kind.rawValue)
    }

    func call(_ target: ObjectHandle, _ method: MethodID, _ arguments: [Slot], results count: Int = 1) -> (RuntimeStatus, [Slot]) {
        var results = [Slot](repeating: 0, count: count)
        let status = arguments.withUnsafeBufferPointer { arguments in
            results.withUnsafeMutableBufferPointer { results in
                runtime.call(target: target, method: method, arguments: arguments, results: results)
            }
        }
        return (status, results)
    }

    func message() -> String {
        String(decoding: runtime.errorMessage(capacity: 1024), as: UTF8.self)
    }

    // MARK: Lookup

    func testClassLookupAndCapabilities() {
        XCTAssertNotEqual(lookup("org.example.Adder"), 0)
        XCTAssertEqual(lookup("org.example.Missing"), 0)
        XCTAssertEqual(lookup("org.example.Adder", guest: FakeGuest(capabilities: [])), 0, "capability not granted")
        XCTAssertNotEqual(lookup("org.example.Adder", guest: FakeGuest(capabilities: [.bluetooth])), 0)
        XCTAssertNotEqual(lookup(BuiltinContracts.listName), 0)
    }

    func testMethodLookup() {
        let cls = lookup("org.example.Adder")
        let add = method(cls, "add:to:", "(II)I", .static)
        XCTAssertNotEqual(add, 0)
        XCTAssertEqual(method(cls, "add:to:", "(II)I", .static), add, "IDs are stable")
        XCTAssertEqual(method(cls, "add:to:", "(IJ)I", .static), 0, "signature mismatch")
        XCTAssertEqual(method(cls, "add:to:", "(II)I", .instance), 0, "kind mismatch")
        XCTAssertEqual(method(cls, "subtract:", "(I)I", .static), 0, "absent method")
        XCTAssertEqual(method(0, "add:to:", "(II)I", .static), 0, "invalid class")
    }

    // MARK: Calls

    func testStaticCall() {
        let add = method(lookup("org.example.Adder"), "add:to:", "(II)I", .static)
        let (status, results) = call(0, add, [Int32(2).slot, Int32(-5).slot])
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(Int32(slot: results[0]), -3)
        XCTAssertEqual(call(0, add, [Int32(2).slot]).0, .signature, "wrong argument count")
    }

    func testThrownErrorsCarryMessages() {
        let make = method(lookup("org.example.Adder"), "make", "()O", .constructor)
        XCTAssertEqual(call(0, make, []).0, .thrown)
        XCTAssertEqual(runtime.errorMessage(capacity: 0), Array("no constructor here".utf8), "size query keeps it")
        XCTAssertEqual(message(), "no constructor here")
        XCTAssertEqual(message(), "", "reading clears it")
    }

    func testInstanceCallOnNull() {
        let value = method(lookup("org.example.Adder"), "value", "()I", .instance)
        XCTAssertEqual(call(0, value, []).0, .null)
        XCTAssertEqual(call(999, value, []).0, .null)
    }

    // MARK: rt_implement

    func testImplementDispatchesToGuest() {
        let listener = lookup("org.example.Listener")
        let object = runtime.implement(
            interfaces: [listener],
            methods: [(Array("heard:".utf8), Array("(I)Z".utf8))],
            context: 7,
            guest: guest
        )
        XCTAssertNotEqual(object, 0)
        XCTAssertTrue(runtime.isInstance(object, of: listener))
        XCTAssertFalse(runtime.isInstance(object, of: lookup("org.example.Adder")))

        guest.reply = { _, arguments in (.ok, (Int32(slot: arguments[0]) > 0).slot) }
        let heard = method(listener, "heard:", "(I)Z", .instance)
        let (status, results) = call(object, heard, [Int32(3).slot])
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(Bool(slot: results[0]))
        XCTAssertEqual(guest.dispatched.first?.context, 7)
        XCTAssertEqual(guest.dispatched.first?.index, 0)

        // A method of another interface isn't routed to it.
        let value = method(lookup("org.example.Adder"), "value", "()I", .instance)
        XCTAssertEqual(call(object, value, []).0, .notFound)
    }

    func testFinalizeOnLastRelease() {
        let object = runtime.implement(interfaces: [lookup("org.example.Listener")], methods: [], context: 3, guest: guest)
        runtime.retain(object)
        runtime.release(object)
        XCTAssertEqual(guest.finalized, [])
        runtime.release(object)
        XCTAssertEqual(guest.finalized, [3])
        XCTAssertEqual(runtime.handleCount, 0)
    }

    func testImplementRejectsUnknownInterfaces() {
        XCTAssertEqual(runtime.implement(interfaces: [999], methods: [], context: 1, guest: guest), 0)
        XCTAssertEqual(runtime.implement(interfaces: [], methods: [], context: 1, guest: guest), 0)
    }

    // MARK: Identity

    func testSameObject() {
        let listener = lookup("org.example.Listener")
        let a = runtime.implement(interfaces: [listener], methods: [], context: 1, guest: guest)
        let b = runtime.implement(interfaces: [listener], methods: [], context: 1, guest: guest)
        let c = runtime.implement(interfaces: [listener], methods: [], context: 2, guest: guest)
        XCTAssertTrue(runtime.same(a, b), "same guest and context")
        XCTAssertFalse(runtime.same(a, c))
        XCTAssertFalse(runtime.same(a, runtime.makeString("x")))
        XCTAssertTrue(runtime.same(0, 0))
    }

    // MARK: Builtins

    func testStringsAndBytes() {
        let string = runtime.makeString("héllo")
        XCTAssertEqual(runtime.stringUTF8(string), Array("héllo".utf8))
        XCTAssertTrue(runtime.isInstance(string, of: lookup(BuiltinContracts.stringName)))
        let bytes = runtime.makeBytes([1, 2, 3])
        XCTAssertEqual(runtime.bytes(bytes), [1, 2, 3])
        XCTAssertNil(runtime.bytes(string))
        runtime.release(string)
        runtime.release(bytes)
        XCTAssertEqual(runtime.handleCount, 0)
    }

    func testList() {
        let list = lookup(BuiltinContracts.listName)
        let make = method(list, "make", "()O", .constructor)
        let append = method(list, "append:", "(O)V", .instance)
        let count = method(list, "count", "()I", .instance)
        let objectAt = method(list, "objectAt:", "(I)O", .instance)

        let handle = call(0, make, []).1[0].handle
        let element = runtime.makeString("a")
        XCTAssertEqual(call(handle, append, [Slot(handle: element)], results: 0).0, .ok)
        runtime.release(element)
        XCTAssertEqual(Int32(slot: call(handle, count, []).1[0]), 1)

        let first = call(handle, objectAt, [Int32(0).slot]).1[0].handle
        XCTAssertEqual(runtime.stringUTF8(first), Array("a".utf8), "the list keeps its elements alive")
        XCTAssertEqual(call(handle, objectAt, [Int32(5).slot]).0, .thrown)
        runtime.release(first)
        runtime.release(handle)
        XCTAssertEqual(runtime.handleCount, 0)
    }

    // MARK: Re-entrancy

    func testFinalizeMayReenter() {
        // The guest releases another object while being finalized.
        let listener = lookup("org.example.Listener")
        let other = runtime.makeString("held by the guest")
        final class ReleasingGuest: Guest {
            var capabilities: Set<Capability>? { nil }
            let runtime: HostRuntime
            let held: ObjectHandle
            init(runtime: HostRuntime, held: ObjectHandle) {
                self.runtime = runtime
                self.held = held
            }
            func dispatch(context: ContextID, index: UInt32, target: ObjectHandle, arguments: UnsafeBufferPointer<Slot>, results: UnsafeMutableBufferPointer<Slot>) -> RuntimeStatus { .ok }
            func finalize(context: ContextID) { runtime.release(held) }
        }
        let releasing = ReleasingGuest(runtime: runtime, held: other)
        let object = runtime.implement(interfaces: [listener], methods: [], context: 1, guest: releasing)
        runtime.release(object)
        XCTAssertEqual(runtime.handleCount, 0)
    }

    // MARK: Validation

    func testValidation() {
        let required = ContractDescriptor(
            name: "org.example.Adder",
            kind: .contract,
            version: 3,
            capability: .bluetooth,
            methods: [
                MethodDescriptor("add:to:", "(II)J", .static),
                MethodDescriptor("value", "()I"),
                MethodDescriptor("reset", "()V"),
            ]
        )
        let missing = ContractDescriptor(name: "org.example.Missing", kind: .contract, methods: [])
        let issues = runtime.validate(abiVersion: 2, contracts: [required, missing], capabilities: [])
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 4, "\(issues)")
        XCTAssertTrue(issues.contains { $0.message.contains("rt ABI 2") })
        XCTAssertTrue(issues.contains { $0.message.contains("capability 'bluetooth'") })
        XCTAssertTrue(issues.contains { $0.contract == "org.example.Missing" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.contains("add:to: is (II)I on this host") })
        XCTAssertTrue(issues.contains { $0.message.contains("reset is absent") && $0.severity == .warning })
        XCTAssertTrue(issues.contains { $0.message.contains("version 2") && $0.severity == .warning })

        XCTAssertEqual(runtime.validate(abiVersion: 1, contracts: [Self.adder], capabilities: [.bluetooth]), [])
    }
}
