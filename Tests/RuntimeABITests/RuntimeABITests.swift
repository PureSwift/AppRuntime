import XCTest
@testable import RuntimeABI

final class RuntimeABITests: XCTestCase {

    // MARK: Signatures

    func testSignatureParsing() throws {
        let signature = try XCTUnwrap(Signature("(ZIJFDO)V"))
        XCTAssertEqual(signature.arguments, [.bool, .int32, .int64, .float32, .float64, .object])
        XCTAssertEqual(signature.result, .void)
        XCTAssertEqual(signature.resultSlotCount, 0)
        XCTAssertEqual(signature.description, "(ZIJFDO)V")
        XCTAssertEqual(Signature("()O")?.resultSlotCount, 1)
    }

    func testMalformedSignatures() {
        for string in ["", "(", "()", "(V)V", "(X)V", "()VV", "I)V", "(I)"] {
            XCTAssertNil(Signature(string), string)
        }
    }

    // MARK: Slots

    func testScalarSlots() {
        XCTAssertEqual(Bool(slot: true.slot), true)
        XCTAssertEqual(false.slot, 0)
        XCTAssertEqual(Int32(slot: Int32(-7).slot), -7)
        XCTAssertEqual(Int32.min.slot, UInt64(bitPattern: Int64(Int32.min)))
        XCTAssertEqual(Int64(slot: Int64.min.slot), .min)
        XCTAssertEqual(Float(slot: Float(1.5).slot), 1.5)
        XCTAssertEqual(Float(1.5).slot >> 32, 0, "f32 uses the low 32 bits")
        XCTAssertEqual(Double(slot: Double.pi.slot), .pi)
        XCTAssertEqual(Slot(handle: 42).handle, 42)
    }

    // MARK: Method keys

    func testMethodKeys() {
        XCTAssertEqual(MethodKey.make(baseName: "stopScan", labels: []), "stopScan")
        XCTAssertEqual(MethodKey.make(baseName: "connect", labels: [nil]), "connect:")
        XCTAssertEqual(MethodKey.make(baseName: "connect", labels: [nil, "timeout"]), "connect:timeout:")
        XCTAssertEqual(MethodKey.make(baseName: "scan", labels: ["services", "allowDuplicates"]), "scan:allowDuplicates:")
        XCTAssertEqual(MethodKey.make(baseName: "replaceSubtree", labels: [nil, nil]), "replaceSubtree::")
        XCTAssertEqual(MethodKey.arity(of: "connect:timeout:"), 2)
        XCTAssertEqual(MethodKey.baseName(of: "connect:timeout:"), "connect")
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

    func testMetadataRoundTrip() throws {
        let section = ContractMetadata.encode(Self.central) + ContractMetadata.encode(Self.delegate)
        XCTAssertEqual(ContractMetadata.decode(section), [Self.central, Self.delegate])
    }

    func testMetadataSkipsLinkerPadding() {
        let section = [0, 0] + ContractMetadata.encode(Self.central) + [0, 0, 0, 0] + ContractMetadata.encode(Self.delegate) + [0]
        XCTAssertEqual(ContractMetadata.decode(section), [Self.central, Self.delegate])
        XCTAssertEqual(ContractMetadata.decode([UInt8]()), [])
    }

    func testMalformedMetadata() {
        var record = ContractMetadata.encode(Self.central)
        XCTAssertNil(ContractMetadata.decode(record.dropLast()), "truncated")
        record[3] = 99
        XCTAssertNil(ContractMetadata.decode(record), "unknown format version")
        XCTAssertNil(ContractMetadata.decode([0x52, 0x54, 0x58]), "bad magic")
    }

    func testDescriptorGroups() {
        XCTAssertEqual(Self.central.staticMethods.map(\.key), ["make:"])
        XCTAssertEqual(Self.central.instanceMethods.map(\.key), ["state", "scan:allowDuplicates:"])
        XCTAssertEqual(Self.central.method(key: "state", kind: .instance)?.signature, Signature("()I"))
        XCTAssertNil(Self.central.method(key: "state", kind: .static))
    }

    // MARK: Errors

    func testErrorStatus() {
        XCTAssertNil(RuntimeError(status: .ok))
        XCTAssertEqual(RuntimeError(status: .thrown, message: "boom"), .thrown("boom"))
        XCTAssertEqual(RuntimeError.null.status, .null)
        XCTAssertEqual(RuntimeStatus(code: 99), .thrown)
    }

    func testBuiltinContracts() {
        XCTAssertEqual(BuiltinContracts.list.name, BuiltinContracts.listName)
        XCTAssertEqual(BuiltinContracts.list.method(key: "objectAt:", kind: .instance)?.signature, Signature("(I)O"))
    }
}
