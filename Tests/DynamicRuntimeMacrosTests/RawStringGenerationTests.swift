import RuntimeABI
import SwiftParser
import SwiftSyntax
import Testing
@testable import DynamicRuntimeMacros

/// Generated code leaves the choice between contract objects and raw string
/// types to the compiler; these pin the calls it makes.
@Suite struct RawStringGenerationTests {

    func generator(_ source: String) throws -> ContractGenerator {
        let file = Parser.parse(source: source)
        let proto = try #require(file.statements.first?.item.as(ProtocolDeclSyntax.self))
        let attribute = try #require(proto.attributes.first?.as(AttributeSyntax.self))
        return ContractGenerator(model: try ContractModel.parse(attribute: attribute, declaration: proto, kind: .contract))
    }

    let source = """
        @DynamicRuntime("t")
        public protocol T: AnyObject {
            func throwing() throws(RuntimeError) -> Identifier
            func plain() -> Identifier
            func throwingList() throws -> [Identifier]
            func take(_ id: Identifier, _ ids: [Identifier]?, _ optional: Identifier?)
        }
        """

    @Test func namedTypesTravelAsObjects() throws {
        let methods = try generator(source).model.descriptor.methods
        #expect(methods.map(\.signature) == [
            Signature("()O"), Signature("()O"), Signature("()O"), Signature("(OOO)V"),
        ])
    }

    @Test func throwingMethodsUseTheCheckedDecoders() throws {
        let proxy = try generator(source).proxyDeclaration()
        #expect(proxy.contains("return try _rtDecodeRetained(results.handle())"))
        #expect(proxy.contains("return try results.list { (handle: ObjectHandle) throws(RuntimeError) in try _rtDecodeRetained(handle) }"))
    }

    @Test func nonThrowingMethodsCantDecodeRawStrings() throws {
        // `_rtResult` is unavailable for RawRepresentable types.
        #expect(try generator(source).proxyDeclaration().contains("return _rtResult(results.handle())"))
    }

    @Test func dispatchDecodesTypedArguments() throws {
        let proxy = try generator(source).proxyDeclaration()
        #expect(proxy.contains("let arg0: Identifier = try _rtDecodeBorrowed(arguments.handle())"))
        #expect(proxy.contains("let arg1: [Identifier]? = try arguments.optionalList"))
        #expect(proxy.contains("let arg2: Identifier? = try arguments.optional"))
    }

    @Test func argumentsEncodeByOverload() throws {
        let proxy = try generator(source).proxyDeclaration()
        #expect(proxy.contains("call.add(retained: _rtEncode(arg0))"))
        #expect(proxy.contains("call.addList(arg1) { _rtEncode($0) }"))
        #expect(proxy.contains("call.add(retained: arg2.map { _rtEncode($0) } ?? 0)"))
    }

    @Test func eachContractEmitsItsOverloads() throws {
        let declarations = try generator(source).marshalingDeclarations()
        #expect(declarations.count == 4)
        #expect(declarations[0].contains("public func _rtEncode(_ value: any T) -> ObjectHandle"))
        #expect(declarations[1].contains("public func _rtDecodeRetained(_ handle: ObjectHandle) throws(RuntimeError) -> any T"))
        #expect(declarations[2].contains("public func _rtDecodeBorrowed(_ handle: ObjectHandle) throws(RuntimeError) -> any T"))
        #expect(declarations[3].contains("public func _rtResult(_ handle: ObjectHandle) -> any T"))
    }
}
