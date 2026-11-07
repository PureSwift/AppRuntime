import RuntimeABI
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@DynamicRuntime("name", version:, requires:)` on a contract protocol.
public struct DynamicRuntimeMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        ContractExpansion.expand(node, declaration, kind: .contract, in: context)
    }
}

/// `@DynamicCallback("name", version:)` on a callback protocol.
public struct DynamicCallbackMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        ContractExpansion.expand(node, declaration, kind: .callback, in: context)
    }
}

enum ContractExpansion {

    static func expand(
        _ node: AttributeSyntax,
        _ declaration: some DeclSyntaxProtocol,
        kind: ContractKind,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        let model: ContractModel
        do throws(ContractError) {
            model = try ContractModel.parse(attribute: node, declaration: declaration, kind: kind)
        } catch {
            for diagnostic in error.diagnostics {
                context.diagnose(diagnostic)
            }
            return []
        }
        let generator = ContractGenerator(model: model)
        return [
            DeclSyntax(stringLiteral: generator.proxyDeclaration()),
            DeclSyntax(stringLiteral: generator.metadataDeclaration()),
        ]
    }
}
