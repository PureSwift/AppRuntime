import RuntimeABI
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import DynamicRuntimeMacros

final class DynamicRuntimeMacrosTests: XCTestCase {

    let macros: [String: Macro.Type] = [
        "DynamicRuntime": DynamicRuntimeMacro.self,
        "DynamicCallback": DynamicCallbackMacro.self,
    ]

    /// Parses the first protocol in `source` with its first attribute.
    func model(_ source: String, kind: ContractKind = .contract) throws -> ContractModel {
        let file = Parser.parse(source: source)
        let proto = try XCTUnwrap(file.statements.first?.item.as(ProtocolDeclSyntax.self))
        let attribute = try XCTUnwrap(proto.attributes.first?.as(AttributeSyntax.self))
        do {
            return try ContractModel.parse(attribute: attribute, declaration: proto, kind: kind)
        } catch {
            XCTFail("unexpected diagnostics: \(error.diagnostics.map(\.message))")
            throw error
        }
    }

    // MARK: Model

    func testCentralContract() throws {
        let model = try model("""
            @DynamicRuntime("org.pureswift.bluetooth.Central", version: 2, requires: .bluetooth)
            public protocol Central: AnyObject {
                static func make(_ delegate: CentralDelegate) -> Self
                func state() -> Int32
                func scan(services: [String], allowDuplicates: Bool)
                func stopScan()
                func connect(_ peripheral: Peripheral, timeout: Int64) throws
                func name() -> String?
                func value() -> [UInt8]
                func peripherals() -> [any Peripheral]
                func ratio(_ x: Float) -> Double
            }
            """)
        XCTAssertEqual(model.runtimeName, "org.pureswift.bluetooth.Central")
        XCTAssertEqual(model.proxyName, "CentralProxy")
        XCTAssertEqual(model.version, 2)
        XCTAssertEqual(model.capability, "bluetooth")
        XCTAssertEqual(model.access, "public ")
        let descriptor = model.descriptor
        XCTAssertEqual(descriptor.methods, [
            MethodDescriptor("make:", "(O)O", .constructor),
            MethodDescriptor("state", "()I"),
            MethodDescriptor("scan:allowDuplicates:", "(OZ)V"),
            MethodDescriptor("stopScan", "()V"),
            MethodDescriptor("connect:timeout:", "(OJ)V"),
            MethodDescriptor("name", "()O"),
            MethodDescriptor("value", "()O"),
            MethodDescriptor("peripherals", "()O"),
            MethodDescriptor("ratio:", "(F)D"),
        ])
        XCTAssertEqual(model.methods.map(\.dispatchIndex), [0, 0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(model.methods[4].throwsClause, "throws")
    }

    func testTypes() throws {
        let model = try model("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func a(_ x: Swift.Int32, _ y: Optional<String>, _ z: Array<UInt8>?, _ w: (any T)?, _ v: [T]?)
            }
            """)
        XCTAssertEqual(model.methods[0].parameters.map(\.type), [
            .scalar(name: "Int32", wire: .int32),
            .optional(.string),
            .optional(.bytes),
            .optional(.object(protocolName: "T")),
            .optional(.objects(protocolName: "T")),
        ])
        XCTAssertEqual(model.access, "")
    }

    func testOverloadsByArityGetDistinctReferences() throws {
        let model = try model("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func connect(_ a: T)
                func connect(_ a: T, timeout: Int32)
            }
            """)
        XCTAssertEqual(model.methods.map(\.referenceName), ["connect_1", "connect_2"])
    }

    func testGeneratedProxyShape() throws {
        let generator = ContractGenerator(model: try model("""
            @DynamicCallback("org.example.Delegate")
            public protocol Delegate: AnyObject {
                func didChange(_ value: Int64) -> Bool
            }
            """, kind: .callback))
        let proxy = generator.proxyDeclaration()
        XCTAssertTrue(proxy.contains("public final class DelegateProxy: DynamicObject, Delegate, DynamicInterface"))
        XCTAssertTrue(proxy.contains("MethodDescriptor(\"didChange:\", \"(J)Z\", .instance)"))
        XCTAssertTrue(proxy.contains("kind: .callback"))
        XCTAssertFalse(proxy.contains("dispatchStatic"), "callbacks have no static methods")
        let metadata = generator.metadataDeclaration()
        XCTAssertTrue(metadata.contains("@section(\"__DATA,__rt_contracts\")"))
        XCTAssertTrue(metadata.contains("@section(\".rt_contracts\")"))
        XCTAssertTrue(metadata.contains("internal let _rt_contract_Delegate"))
        // The section record decodes back to the descriptor.
        XCTAssertEqual(
            ContractMetadata.decode(ContractMetadata.encode(generator.model.descriptor)),
            [generator.model.descriptor]
        )
    }

    // MARK: Diagnostics

    func diagnostics(_ source: String) -> [String] {
        let file = Parser.parse(source: source)
        let context = BasicMacroExpansionContext(sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
        _ = file.expand(macros: macros, in: context)
        return context.diagnostics.map(\.message)
    }

    func testRequiresClassBound() {
        assertMacroExpansion(
            """
            @DynamicRuntime("t")
            protocol T {
                func a()
            }
            """,
            expandedSource: """
                protocol T {
                    func a()
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: ContractDiagnostic.notClassBound.message,
                    line: 2,
                    column: 10,
                    fixIts: [FixItSpec(message: "add ': AnyObject'")]
                ),
            ],
            macros: macros
        )
    }

    func testRejectsUnsupportedTypes() {
        let messages = diagnostics("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func a(_ x: Int)
                func b() -> UInt32
                func c(_ x: [Int32])
                func d() async
                func e(_ x: inout Int32)
                var f: Int32 { get }
                func g() -> Self
                func h<X>(_ x: X)
                func i() throws(MyError)
            }
            """)
        XCTAssertEqual(messages.count, 9, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("'Int'") && $0.contains("Int32 or Int64") })
        XCTAssertTrue(messages.contains { $0.contains("'UInt32'") })
        XCTAssertTrue(messages.contains { $0.contains("arrays may hold String or object types only") })
        XCTAssertTrue(messages.contains { $0.contains("async") })
        XCTAssertTrue(messages.contains(ContractDiagnostic.unsupportedMember.message))
        XCTAssertTrue(messages.contains { $0.contains("'Self' is only allowed") })
        XCTAssertTrue(messages.contains { $0.contains("generic") })
        XCTAssertTrue(messages.contains { $0.contains("may only throw 'RuntimeError'") })
    }

    func testRejectsOverloadsAndStaticCallbacks() {
        XCTAssertEqual(diagnostics("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func a(_ x: Int32)
                func a(y: Bool)
            }
            """), [ContractDiagnostic.overload("a", 1).message])
        XCTAssertEqual(diagnostics("""
            @DynamicCallback("t")
            protocol T: AnyObject {
                static func make() -> Self
            }
            """), [ContractDiagnostic.staticInCallback("make").message])
    }

    func testRejectsBadArguments() {
        XCTAssertEqual(diagnostics("""
            @DynamicRuntime(name)
            protocol T: AnyObject { }
            """), [ContractDiagnostic.missingName("DynamicRuntime").message])
        XCTAssertEqual(diagnostics("""
            @DynamicRuntime("t", version: 0)
            protocol T: AnyObject { }
            """), [ContractDiagnostic.invalidVersion.message])
        XCTAssertEqual(diagnostics("""
            @DynamicRuntime("t")
            struct T { }
            """), [ContractDiagnostic.notAProtocol("DynamicRuntime").message])
    }
}
