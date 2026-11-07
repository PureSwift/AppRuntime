import RuntimeABI
import SwiftDiagnostics
import SwiftSyntax

/// A parsed `@DynamicRuntime` or `@DynamicCallback` protocol.
struct ContractModel {

    /// Swift protocol name.
    let protocolName: String

    /// Reverse-DNS runtime name.
    let runtimeName: String

    let kind: ContractKind

    let version: UInt32

    let capability: String?

    /// `public ` or empty, applied to generated declarations.
    let access: String

    let methods: [ContractMethod]

    var proxyName: String {
        protocolName + "Proxy"
    }

    var descriptor: ContractDescriptor {
        ContractDescriptor(
            name: runtimeName,
            kind: kind,
            version: version,
            capability: capability.map(Capability.init(rawValue:)),
            methods: methods.map(\.descriptor)
        )
    }
}

struct ContractParameter {

    /// External label, `nil` for `_`.
    let label: String?

    /// Generated internal name.
    let name: String

    /// Original type spelling.
    let typeText: String

    let type: ContractType
}

struct ContractMethod {

    let baseName: String

    let kind: MethodKind

    let parameters: [ContractParameter]

    /// Original result type spelling, `nil` for no result.
    let resultText: String?

    let result: ContractType?

    /// The original throws clause (`throws` or `throws(RuntimeError)`).
    let throwsClause: String?

    /// Position among methods of the same group: instance methods, or static
    /// and constructor methods. This is the dispatch index.
    var dispatchIndex: Int = 0

    /// Name of the generated `MethodReference`.
    var referenceName: String = ""

    var key: String {
        MethodKey.make(baseName: baseName, labels: parameters.map(\.label))
    }

    var signature: Signature {
        Signature(
            arguments: parameters.map(\.type.wireType),
            result: result?.wireType ?? .void
        )
    }

    var descriptor: MethodDescriptor {
        MethodDescriptor(key: key, signature: signature, kind: kind)
    }

    var isThrowing: Bool {
        throwsClause != nil
    }

    /// Whether the throws clause is typed (`throws(RuntimeError)`).
    var isTypedThrows: Bool {
        throwsClause?.contains("(") == true
    }
}

// MARK: - Parsing

extension ContractModel {

    static func parse(
        attribute: AttributeSyntax,
        declaration: some DeclSyntaxProtocol,
        kind: ContractKind
    ) throws(ContractError) -> ContractModel {
        let attributeName = kind == .contract ? "DynamicRuntime" : "DynamicCallback"
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw ContractError(.notAProtocol(attributeName), at: attribute)
        }
        let arguments = try parseArguments(attribute, attributeName: attributeName)
        var diagnostics = [Diagnostic]()

        // Class-bound, with nothing else inherited.
        let inherited = proto.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        if !inherited.contains("AnyObject") {
            diagnostics.append(notClassBoundDiagnostic(proto))
        }
        for type in proto.inheritanceClause?.inheritedTypes ?? [] where type.type.trimmedDescription != "AnyObject" {
            diagnostics.append(Diagnostic(node: type, message: ContractDiagnostic.unsupportedInheritance(type.type.trimmedDescription)))
        }
        if proto.primaryAssociatedTypeClause != nil || proto.genericWhereClause != nil {
            diagnostics.append(Diagnostic(node: proto.name, message: ContractDiagnostic.genericProtocol))
        }

        var methods = [ContractMethod]()
        var methodNodes = [DeclSyntax]()
        for member in proto.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else {
                diagnostics.append(Diagnostic(node: member.decl, message: ContractDiagnostic.unsupportedMember))
                continue
            }
            do throws(ContractError) {
                methods.append(try parseMethod(function, contractKind: kind))
                methodNodes.append(member.decl)
            } catch {
                diagnostics.append(contentsOf: error.diagnostics)
            }
        }

        // No overloads: base name + arity must be unique.
        var seen = Set<String>()
        for (method, node) in zip(methods, methodNodes) {
            let identity = "\(method.baseName)/\(method.parameters.count)"
            if !seen.insert(identity).inserted {
                diagnostics.append(Diagnostic(node: node, message: ContractDiagnostic.overload(method.baseName, method.parameters.count)))
            }
        }

        guard diagnostics.isEmpty else {
            throw ContractError(diagnostics)
        }

        // Dispatch indices and reference names.
        var instanceIndex = 0
        var staticIndex = 0
        let baseNameCounts = Dictionary(grouping: methods, by: \.baseName).mapValues(\.count)
        for index in methods.indices {
            if methods[index].kind == .instance {
                methods[index].dispatchIndex = instanceIndex
                instanceIndex += 1
            } else {
                methods[index].dispatchIndex = staticIndex
                staticIndex += 1
            }
            let baseName = methods[index].baseName
            methods[index].referenceName = baseNameCounts[baseName, default: 0] > 1
                ? "\(baseName)_\(methods[index].parameters.count)"
                : baseName
        }

        let isPublic = proto.modifiers.contains { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }
        return ContractModel(
            protocolName: proto.name.text,
            runtimeName: arguments.name,
            kind: kind,
            version: arguments.version,
            capability: arguments.capability,
            access: isPublic ? "public " : "",
            methods: methods
        )
    }

    private static func notClassBoundDiagnostic(_ proto: ProtocolDeclSyntax) -> Diagnostic {
        let fixed: ProtocolDeclSyntax
        if let clause = proto.inheritanceClause {
            var types = clause.inheritedTypes
            if var last = types.last {
                types = InheritedTypeListSyntax(types.dropLast())
                last.trailingComma = .commaToken(trailingTrivia: .space)
                types.append(last)
            }
            types.append(InheritedTypeSyntax(type: TypeSyntax("AnyObject")))
            fixed = proto.with(\.inheritanceClause, clause.with(\.inheritedTypes, types))
        } else {
            fixed = proto
                .with(\.name, proto.name.with(\.trailingTrivia, []))
                .with(\.inheritanceClause, InheritanceClauseSyntax(
                    colon: .colonToken(trailingTrivia: .space),
                    inheritedTypes: [InheritedTypeSyntax(type: TypeSyntax("AnyObject"), trailingTrivia: .space)]
                ))
        }
        return Diagnostic(
            node: proto.name,
            message: ContractDiagnostic.notClassBound,
            fixIt: FixIt(message: AddAnyObjectFixIt(), changes: [.replace(oldNode: Syntax(proto), newNode: Syntax(fixed))])
        )
    }

    private struct Arguments {
        var name: String
        var version: UInt32 = 1
        var capability: String?
    }

    private static func parseArguments(_ attribute: AttributeSyntax, attributeName: String) throws(ContractError) -> Arguments {
        guard let list = attribute.arguments?.as(LabeledExprListSyntax.self),
              let first = list.first, first.label == nil,
              let literal = first.expression.as(StringLiteralExprSyntax.self),
              let name = literal.representedLiteralValue, !name.isEmpty else {
            throw ContractError(.missingName(attributeName), at: attribute)
        }
        var arguments = Arguments(name: name)
        for argument in list.dropFirst() {
            switch argument.label?.text {
            case "version":
                guard let integer = argument.expression.as(IntegerLiteralExprSyntax.self),
                      let version = UInt32(String(integer.literal.text.filter { $0 != "_" })),
                      version > 0 else {
                    throw ContractError(.invalidVersion, at: argument.expression)
                }
                arguments.version = version
            case "requires":
                arguments.capability = try parseCapability(argument.expression)
            default:
                break
            }
        }
        return arguments
    }

    private static func parseCapability(_ expression: ExprSyntax) throws(ContractError) -> String? {
        if expression.is(NilLiteralExprSyntax.self) {
            return nil
        }
        if let member = expression.as(MemberAccessExprSyntax.self), member.base == nil || member.base?.trimmedDescription == "Capability" {
            return member.declName.baseName.text
        }
        if let literal = expression.as(StringLiteralExprSyntax.self), let value = literal.representedLiteralValue, !value.isEmpty {
            return value
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription == "Capability",
           let argument = call.arguments.first?.expression.as(StringLiteralExprSyntax.self),
           let value = argument.representedLiteralValue, !value.isEmpty {
            return value
        }
        throw ContractError(.invalidCapability, at: expression)
    }

    private static func parseMethod(_ function: FunctionDeclSyntax, contractKind: ContractKind) throws(ContractError) -> ContractMethod {
        let name = function.name.text.filter { $0 != "`" }
        var diagnostics = [Diagnostic]()
        if function.genericParameterClause != nil || function.genericWhereClause != nil {
            diagnostics.append(Diagnostic(node: function.name, message: ContractDiagnostic.genericMethod(name)))
        }
        let effects = function.signature.effectSpecifiers
        if effects?.asyncSpecifier != nil {
            diagnostics.append(Diagnostic(node: function.name, message: ContractDiagnostic.asyncMethod(name)))
        }
        var throwsClause: String?
        if let clause = effects?.throwsClause {
            if clause.throwsSpecifier.tokenKind == .keyword(.rethrows) {
                diagnostics.append(Diagnostic(node: clause, message: ContractDiagnostic.rethrowsMethod(name)))
            } else if let type = clause.type {
                let typeName = type.trimmedDescription
                if typeName == "RuntimeError" || typeName.hasSuffix(".RuntimeError") {
                    throwsClause = "throws(\(typeName))"
                } else {
                    diagnostics.append(Diagnostic(node: type, message: ContractDiagnostic.unsupportedThrowsType(name)))
                }
            } else {
                throwsClause = "throws"
            }
        }
        let isStatic = function.modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
        if isStatic, contractKind == .callback {
            diagnostics.append(Diagnostic(node: function.name, message: ContractDiagnostic.staticInCallback(name)))
        }

        var parameters = [ContractParameter]()
        for (index, parameter) in function.signature.parameterClause.parameters.enumerated() {
            if parameter.ellipsis != nil || parameter.defaultValue != nil
                || parameter.type.as(AttributedTypeSyntax.self) != nil {
                diagnostics.append(Diagnostic(node: parameter, message: ContractDiagnostic.unsupportedParameter(name)))
                continue
            }
            do throws(ContractError) {
                let type = try ContractType.parse(parameter.type)
                if type == .selfType || type == .optional(.selfType) {
                    diagnostics.append(Diagnostic(node: parameter.type, message: ContractDiagnostic.selfOutsideConstructor(name)))
                    continue
                }
                let label = parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.text.filter { $0 != "`" }
                parameters.append(ContractParameter(
                    label: label,
                    name: "arg\(index)",
                    typeText: parameter.type.trimmedDescription,
                    type: type
                ))
            } catch {
                diagnostics.append(contentsOf: error.diagnostics)
            }
        }

        var result: ContractType?
        var resultText: String?
        if let returnType = function.signature.returnClause?.type {
            do throws(ContractError) {
                result = try ContractType.parse(returnType)
                resultText = returnType.trimmedDescription
            } catch {
                diagnostics.append(contentsOf: error.diagnostics)
            }
        }
        let returnsSelf = result == .selfType || result == .optional(.selfType)
        if returnsSelf, !isStatic {
            diagnostics.append(Diagnostic(node: function.name, message: ContractDiagnostic.selfOutsideConstructor(name)))
        }

        guard diagnostics.isEmpty else {
            throw ContractError(diagnostics)
        }
        let kind: MethodKind = isStatic ? (returnsSelf ? .constructor : .static) : .instance
        return ContractMethod(
            baseName: name,
            kind: kind,
            parameters: parameters,
            resultText: resultText,
            result: result,
            throwsClause: throwsClause
        )
    }
}
