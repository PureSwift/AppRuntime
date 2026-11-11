import Testing
@testable import RuntimeABI

@Suite struct RuntimeABITests {

    // MARK: Signatures

    @Test func signatureParsing() throws {
        let signature = try #require(Signature("(ZIJFDO)V"))
        #expect(signature.arguments == [.bool, .int32, .int64, .float32, .float64, .object])
        #expect(signature.result == .void)
        #expect(signature.resultSlotCount == 0)
        #expect(signature.description == "(ZIJFDO)V")
        #expect(Signature("()O")?.resultSlotCount == 1)
    }

    @Test func malformedSignatures() {
        for string in ["", "(", "()", "(V)V", "(X)V", "()VV", "I)V", "(I)"] {
            #expect(Signature(string) == nil, "\(string)")
        }
    }

    // MARK: Slots

    @Test func scalarSlots() {
        #expect(Bool(slot: true.slot) == true)
        #expect(false.slot == 0)
        #expect(Int32(slot: Int32(-7).slot) == -7)
        #expect(Int32.min.slot == UInt64(bitPattern: Int64(Int32.min)))
        #expect(Int64(slot: Int64.min.slot) == .min)
        #expect(Float(slot: Float(1.5).slot) == 1.5)
        #expect(Float(1.5).slot >> 32 == 0, "f32 uses the low 32 bits")
        #expect(Double(slot: Double.pi.slot) == .pi)
        #expect(Slot(handle: 42).handle == 42)
    }

    // MARK: Method keys

    @Test func methodKeys() {
        #expect(MethodKey.make(baseName: "stopScan", labels: []) == "stopScan")
        #expect(MethodKey.make(baseName: "connect", labels: [nil]) == "connect:")
        #expect(MethodKey.make(baseName: "connect", labels: [nil, "timeout"]) == "connect:timeout:")
        #expect(MethodKey.make(baseName: "scan", labels: ["services", "allowDuplicates"]) == "scan:allowDuplicates:")
        #expect(MethodKey.make(baseName: "replaceSubtree", labels: [nil, nil]) == "replaceSubtree::")
        #expect(MethodKey.arity(of: "connect:timeout:") == 2)
        #expect(MethodKey.baseName(of: "connect:timeout:") == "connect")
    }

    // MARK: Metadata

    static let central = ContractDescriptor(
        name: "org.pureswift.bluetooth.Central",
        kind: .contract,
        version: 3,
        capability: .bluetooth,
        methods: [
            MethodDescriptor("make:", "(O)O", .constructor),
            MethodDescriptor("state", "()I"),
            MethodDescriptor("scan:allowDuplicates:", "(OZ)V"),
        ]
    )

    static let delegate = ContractDescriptor(
        name: "org.pureswift.bluetooth.CentralDelegate",
        kind: .callback,
        methods: [MethodDescriptor("didUpdateState:", "(O)V")]
    )

    @Test func metadataRoundTrip() throws {
        let section = ContractMetadata.encode(Self.central) + ContractMetadata.encode(Self.delegate)
        #expect(ContractMetadata.decode(section) == [Self.central, Self.delegate])
    }

    @Test func metadataSkipsLinkerPadding() {
        let section = [0, 0] + ContractMetadata.encode(Self.central) + [0, 0, 0, 0] + ContractMetadata.encode(Self.delegate) + [0]
        #expect(ContractMetadata.decode(section) == [Self.central, Self.delegate])
        #expect(ContractMetadata.decode([UInt8]()) == [])
    }

    @Test func malformedMetadata() {
        var record = ContractMetadata.encode(Self.central)
        #expect(ContractMetadata.decode(record.dropLast()) == nil, "truncated")
        record[3] = 99
        #expect(ContractMetadata.decode(record) == nil, "unknown format version")
        #expect(ContractMetadata.decode([0x52, 0x54, 0x58]) == nil, "bad magic")
    }

    @Test func descriptorGroups() {
        #expect(Self.central.staticMethods.map(\.key) == ["make:"])
        #expect(Self.central.instanceMethods.map(\.key) == ["state", "scan:allowDuplicates:"])
        #expect(Self.central.method(key: "state", kind: .instance)?.signature == Signature("()I"))
        #expect(Self.central.method(key: "state", kind: .static) == nil)
    }

    // MARK: Errors

    @Test func errorStatus() {
        #expect(RuntimeError(status: .ok) == nil)
        #expect(RuntimeError(status: .thrown, message: "boom") == .thrown("boom"))
        #expect(RuntimeError.null.status == .null)
        #expect(RuntimeStatus(code: 99) == .thrown)
    }

    @Test func builtinContracts() {
        #expect(BuiltinContracts.list.name == BuiltinContracts.listName)
        #expect(BuiltinContracts.list.method(key: "objectAt:", kind: .instance)?.signature == Signature("(I)O"))
        #expect(BuiltinContracts.clock.name == BuiltinContracts.clockName)
        #expect(BuiltinContracts.clock.method(key: "after:delegate:", kind: .static)?.signature == Signature("(JO)V"))
        #expect(BuiltinContracts.clock.instanceMethods.isEmpty)
        #expect(BuiltinContracts.clockDelegate.kind == .callback)
        #expect(BuiltinContracts.clockDelegate.instanceMethods.map(\.key) == ["fire"])
        #expect(BuiltinContracts.all.map(\.name).contains(BuiltinContracts.clockDelegateName))
    }
}
