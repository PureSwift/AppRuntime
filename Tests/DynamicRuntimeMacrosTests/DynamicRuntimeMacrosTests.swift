import RuntimeABI
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
@testable import DynamicRuntimeMacros

@Suite struct DynamicRuntimeMacrosTests {

    let macros: [String: Macro.Type] = [
        "DynamicRuntime": DynamicRuntimeMacro.self,
        "DynamicCallback": DynamicCallbackMacro.self,
    ]

    /// Parses the first protocol in `source` with its first attribute.
    func model(_ source: String, kind: ContractKind = .contract) throws -> ContractModel {
        let file = Parser.parse(source: source)
        let proto = try #require(file.statements.first?.item.as(ProtocolDeclSyntax.self))
        let attribute = try #require(proto.attributes.first?.as(AttributeSyntax.self))
        do {
            return try ContractModel.parse(attribute: attribute, declaration: proto, kind: kind)
        } catch {
            Issue.record("unexpected diagnostics: \(error.diagnostics.map(\.message))")
            throw error
        }
    }

    // MARK: Model

    @Test func centralContract() throws {
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
        #expect(model.runtimeName == "org.pureswift.bluetooth.Central")
        #expect(model.proxyName == "CentralProxy")
        #expect(model.version == 2)
        #expect(model.capability == "bluetooth")
        #expect(model.access == "public ")
        let descriptor = model.descriptor
        #expect(descriptor.methods == [
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
        #expect(model.methods.map(\.dispatchIndex) == [0, 0, 1, 2, 3, 4, 5, 6, 7])
        #expect(model.methods[4].throwsClause == "throws")
    }

    @Test func types() throws {
        let model = try model("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func a(_ x: Swift.Int32, _ y: Optional<String>, _ z: Array<UInt8>?, _ w: (any T)?, _ v: [T]?)
            }
            """)
        #expect(model.methods[0].parameters.map(\.type) == [
            .scalar(name: "Int32", wire: .int32),
            .optional(.string),
            .optional(.bytes),
            .optional(.object(protocolName: "T")),
            .optional(.objects(protocolName: "T")),
        ])
        #expect(model.access == "")
    }

    @Test func overloadsByArityGetDistinctReferences() throws {
        let model = try model("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func connect(_ a: T)
                func connect(_ a: T, timeout: Int32)
            }
            """)
        #expect(model.methods.map(\.referenceName) == ["connect_1", "connect_2"])
    }

    @Test func generatedProxyShape() throws {
        let generator = ContractGenerator(model: try model("""
            @DynamicCallback("org.example.Delegate")
            public protocol Delegate: AnyObject {
                func didChange(_ value: Int64) -> Bool
            }
            """, kind: .callback))
        let proxy = generator.proxyDeclaration()
        #expect(proxy.contains("public final class DelegateProxy: DynamicObject, Delegate, DynamicInterface"))
        #expect(proxy.contains("MethodDescriptor(\"didChange:\", \"(J)Z\", .instance)"))
        #expect(proxy.contains("kind: .callback"))
        #expect(!proxy.contains("dispatchStatic"), "callbacks have no static methods")
        let metadata = generator.metadataDeclaration()
        #expect(metadata.contains("@section(\"__DATA,__rt_contracts\")"))
        #expect(metadata.contains("@section(\".rt_contracts\")"))
        #expect(metadata.contains("internal let _rt_contract_Delegate"))
        // The section record decodes back to the descriptor.
        #expect(ContractMetadata.decode(ContractMetadata.encode(generator.model.descriptor)) == [generator.model.descriptor])
    }

    /// Every host provides the built-ins, so apps don't list them.
    @Test func builtinContractsHaveNoMetadataRecord() {
        func expanded(_ name: String) -> String {
            let file = Parser.parse(source: """
                @DynamicRuntime("\(name)")
                public protocol Thing: AnyObject {
                    static func value() -> Int32
                }
                """)
            let context = BasicMacroExpansionContext(sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
            return file.expand(macros: macros, in: context).description
        }
        #expect(!expanded("org.pureswift.runtime.Thing").contains("_rt_contract_"))
        #expect(expanded("org.example.Thing").contains("_rt_contract_Thing"))
        #expect(BuiltinContracts.all.allSatisfy { BuiltinContracts.isBuiltin($0.name) })
    }

    // MARK: Diagnostics

    func diagnostics(_ source: String) -> [String] {
        let file = Parser.parse(source: source)
        let context = BasicMacroExpansionContext(sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
        _ = file.expand(macros: macros, in: context)
        return context.diagnostics.map(\.message)
    }

    @Test func requiresClassBound() {
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
            macroSpecs: macros.mapValues { MacroSpec(type: $0) },
            failureHandler: { failure in
                Issue.record(
                    "\(failure.message)",
                    sourceLocation: SourceLocation(
                        fileID: failure.location.fileID,
                        filePath: failure.location.filePath,
                        line: failure.location.line,
                        column: failure.location.column
                    )
                )
            }
        )
    }

    @Test func rejectsUnsupportedTypes() {
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
        #expect(messages.count == 9, "\(messages)")
        #expect(messages.contains { $0.contains("'Int'") && $0.contains("Int32 or Int64") })
        #expect(messages.contains { $0.contains("'UInt32'") })
        #expect(messages.contains { $0.contains("arrays may hold String or object types only") })
        #expect(messages.contains { $0.contains("async") })
        #expect(messages.contains(ContractDiagnostic.unsupportedMember.message))
        #expect(messages.contains { $0.contains("'Self' is only allowed") })
        #expect(messages.contains { $0.contains("generic") })
        #expect(messages.contains { $0.contains("may only throw 'RuntimeError'") })
    }

    @Test func rejectsOverloadsAndStaticCallbacks() {
        #expect(diagnostics("""
            @DynamicRuntime("t")
            protocol T: AnyObject {
                func a(_ x: Int32)
                func a(y: Bool)
            }
            """) == [ContractDiagnostic.overload("a", 1).message])
        #expect(diagnostics("""
            @DynamicCallback("t")
            protocol T: AnyObject {
                static func make() -> Self
            }
            """) == [ContractDiagnostic.staticInCallback("make").message])
    }

    @Test func rejectsBadArguments() {
        #expect(diagnostics("""
            @DynamicRuntime(name)
            protocol T: AnyObject { }
            """) == [ContractDiagnostic.missingName("DynamicRuntime").message])
        #expect(diagnostics("""
            @DynamicRuntime("t", version: 0)
            protocol T: AnyObject { }
            """) == [ContractDiagnostic.invalidVersion.message])
        #expect(diagnostics("""
            @DynamicRuntime("t")
            struct T { }
            """) == [ContractDiagnostic.notAProtocol("DynamicRuntime").message])
    }
}
