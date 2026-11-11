import Testing
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

@Suite struct HostRuntimeTests {

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

    let runtime = HostRuntime()

    let guest = FakeGuest()

    /// Swift Testing makes a new instance, so a new runtime, for every test.
    init() {
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

    @Test func classLookupAndCapabilities() {
        #expect(lookup("org.example.Adder") != 0)
        #expect(lookup("org.example.Missing") == 0)
        #expect(lookup("org.example.Adder", guest: FakeGuest(capabilities: [])) == 0, "capability not granted")
        #expect(lookup("org.example.Adder", guest: FakeGuest(capabilities: [.bluetooth])) != 0)
        #expect(lookup(BuiltinContracts.listName) != 0)
    }

    @Test func methodLookup() {
        let cls = lookup("org.example.Adder")
        let add = method(cls, "add:to:", "(II)I", .static)
        #expect(add != 0)
        #expect(method(cls, "add:to:", "(II)I", .static) == add, "IDs are stable")
        #expect(method(cls, "add:to:", "(IJ)I", .static) == 0, "signature mismatch")
        #expect(method(cls, "add:to:", "(II)I", .instance) == 0, "kind mismatch")
        #expect(method(cls, "subtract:", "(I)I", .static) == 0, "absent method")
        #expect(method(0, "add:to:", "(II)I", .static) == 0, "invalid class")
    }

    // MARK: Calls

    @Test func staticCall() {
        let add = method(lookup("org.example.Adder"), "add:to:", "(II)I", .static)
        let (status, results) = call(0, add, [Int32(2).slot, Int32(-5).slot])
        #expect(status == .ok)
        #expect(Int32(slot: results[0]) == -3)
        #expect(call(0, add, [Int32(2).slot]).0 == .signature, "wrong argument count")
    }

    @Test func thrownErrorsCarryMessages() {
        let make = method(lookup("org.example.Adder"), "make", "()O", .constructor)
        #expect(call(0, make, []).0 == .thrown)
        #expect(runtime.errorMessage(capacity: 0) == Array("no constructor here".utf8), "size query keeps it")
        #expect(message() == "no constructor here")
        #expect(message() == "", "reading clears it")
    }

    @Test func instanceCallOnNull() {
        let value = method(lookup("org.example.Adder"), "value", "()I", .instance)
        #expect(call(0, value, []).0 == .null)
        #expect(call(999, value, []).0 == .null)
    }

    // MARK: rt_implement

    @Test func implementDispatchesToGuest() {
        let listener = lookup("org.example.Listener")
        let object = runtime.implement(
            interfaces: [listener],
            methods: [(Array("heard:".utf8), Array("(I)Z".utf8))],
            context: 7,
            guest: guest
        )
        #expect(object != 0)
        #expect(runtime.isInstance(object, of: listener))
        #expect(!runtime.isInstance(object, of: lookup("org.example.Adder")))

        guest.reply = { _, arguments in (.ok, (Int32(slot: arguments[0]) > 0).slot) }
        let heard = method(listener, "heard:", "(I)Z", .instance)
        let (status, results) = call(object, heard, [Int32(3).slot])
        #expect(status == .ok)
        #expect(Bool(slot: results[0]))
        #expect(guest.dispatched.first?.context == 7)
        #expect(guest.dispatched.first?.index == 0)

        // A method of another interface isn't routed to it.
        let value = method(lookup("org.example.Adder"), "value", "()I", .instance)
        #expect(call(object, value, []).0 == .notFound)
    }

    @Test func finalizeOnLastRelease() {
        let object = runtime.implement(interfaces: [lookup("org.example.Listener")], methods: [], context: 3, guest: guest)
        runtime.retain(object)
        runtime.release(object)
        #expect(guest.finalized == [])
        runtime.release(object)
        #expect(guest.finalized == [3])
        #expect(runtime.handleCount == 0)
    }

    @Test func implementRejectsUnknownInterfaces() {
        #expect(runtime.implement(interfaces: [999], methods: [], context: 1, guest: guest) == 0)
        #expect(runtime.implement(interfaces: [], methods: [], context: 1, guest: guest) == 0)
    }

    // MARK: Identity

    @Test func sameObject() {
        let listener = lookup("org.example.Listener")
        let a = runtime.implement(interfaces: [listener], methods: [], context: 1, guest: guest)
        let b = runtime.implement(interfaces: [listener], methods: [], context: 1, guest: guest)
        let c = runtime.implement(interfaces: [listener], methods: [], context: 2, guest: guest)
        #expect(runtime.same(a, b), "same guest and context")
        #expect(!runtime.same(a, c))
        #expect(!runtime.same(a, runtime.makeString("x")))
        #expect(runtime.same(0, 0))
    }

    // MARK: Builtins

    @Test func stringsAndBytes() {
        let string = runtime.makeString("héllo")
        #expect(runtime.stringUTF8(string) == Array("héllo".utf8))
        #expect(runtime.isInstance(string, of: lookup(BuiltinContracts.stringName)))
        let bytes = runtime.makeBytes([1, 2, 3])
        #expect(runtime.bytes(bytes) == [1, 2, 3])
        #expect(runtime.bytes(string) == nil)
        runtime.release(string)
        runtime.release(bytes)
        #expect(runtime.handleCount == 0)
    }

    @Test func list() {
        let list = lookup(BuiltinContracts.listName)
        let make = method(list, "make", "()O", .constructor)
        let append = method(list, "append:", "(O)V", .instance)
        let count = method(list, "count", "()I", .instance)
        let objectAt = method(list, "objectAt:", "(I)O", .instance)

        let handle = call(0, make, []).1[0].handle
        let element = runtime.makeString("a")
        #expect(call(handle, append, [Slot(handle: element)], results: 0).0 == .ok)
        runtime.release(element)
        #expect(Int32(slot: call(handle, count, []).1[0]) == 1)

        let first = call(handle, objectAt, [Int32(0).slot]).1[0].handle
        #expect(runtime.stringUTF8(first) == Array("a".utf8), "the list keeps its elements alive")
        #expect(call(handle, objectAt, [Int32(5).slot]).0 == .thrown)
        runtime.release(first)
        runtime.release(handle)
        #expect(runtime.handleCount == 0)
    }

    // MARK: Re-entrancy

    @Test func finalizeMayReenter() {
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
        #expect(runtime.handleCount == 0)
    }

    // MARK: Validation

    @Test func validation() {
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
        #expect(issues.filter { $0.severity == .error }.count == 4, "\(issues)")
        #expect(issues.contains { $0.message.contains("rt ABI 2") })
        #expect(issues.contains { $0.message.contains("capability 'bluetooth'") })
        #expect(issues.contains { $0.contract == "org.example.Missing" && $0.severity == .error })
        #expect(issues.contains { $0.message.contains("add:to: is (II)I on this host") })
        #expect(issues.contains { $0.message.contains("reset is absent") && $0.severity == .warning })
        #expect(issues.contains { $0.message.contains("version 2") && $0.severity == .warning })

        #expect(runtime.validate(abiVersion: 1, contracts: [Self.adder], capabilities: [.bluetooth]) == [])
    }
}
