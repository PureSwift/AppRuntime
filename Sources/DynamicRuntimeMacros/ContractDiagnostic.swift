import SwiftDiagnostics
import SwiftSyntax

/// Contract-rule violations reported by `@DynamicRuntime` / `@DynamicCallback`.
enum ContractDiagnostic: DiagnosticMessage {

    case notAProtocol(String)
    case missingName(String)
    case invalidVersion
    case invalidCapability
    case notClassBound
    case unsupportedInheritance(String)
    case genericProtocol
    case unsupportedMember
    case genericMethod(String)
    case asyncMethod(String)
    case rethrowsMethod(String)
    case unsupportedThrowsType(String)
    case unsupportedParameter(String)
    case unsupportedType(String, hint: String?)
    case selfOutsideConstructor(String)
    case staticInCallback(String)
    case overload(String, Int)

    var message: String {
        switch self {
        case .notAProtocol(let attribute):
            return "@\(attribute) can only be attached to a protocol"
        case .missingName(let attribute):
            return "@\(attribute) needs a contract name string literal, for example \"org.example.Thing\""
        case .invalidVersion:
            return "contract version must be a positive integer literal"
        case .invalidCapability:
            return "capability must be written as a member such as '.bluetooth', a string literal, or 'nil'"
        case .notClassBound:
            return "contract protocols must be class-bound (': AnyObject') so they can be used as existentials in Embedded Swift"
        case .unsupportedInheritance(let name):
            return "contract protocols can't inherit '\(name)'; only 'AnyObject' is allowed"
        case .genericProtocol:
            return "contract protocols can't have primary associated types or 'where' clauses"
        case .unsupportedMember:
            return "contract protocols may only declare methods"
        case .genericMethod(let name):
            return "contract method '\(name)' can't be generic"
        case .asyncMethod(let name):
            return "contract method '\(name)' can't be 'async'; use a callback interface, and add async wrappers on the guest side"
        case .rethrowsMethod(let name):
            return "contract method '\(name)' can't be 'rethrows'"
        case .unsupportedThrowsType(let name):
            return "contract method '\(name)' may only throw 'RuntimeError'"
        case .unsupportedParameter(let name):
            return "contract method '\(name)' can't have variadic, inout or default parameters"
        case .unsupportedType(let type, let hint):
            let base = "type '\(type)' can't cross the runtime boundary"
            return hint.map { "\(base); \($0)" } ?? base
        case .selfOutsideConstructor(let name):
            return "'Self' is only allowed as the return type of a static constructor ('\(name)')"
        case .staticInCallback(let name):
            return "callback interfaces can't declare static methods ('\(name)')"
        case .overload(let name, let arity):
            return "contracts can't overload methods: '\(name)' with \(arity) argument(s) is declared more than once"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "DynamicRuntimeMacros", id: String(describing: self).prefix { $0 != "(" }.description)
    }

    var severity: DiagnosticSeverity { .error }
}

/// Fix-it that adds `: AnyObject` to a protocol.
struct AddAnyObjectFixIt: FixItMessage {

    var message: String { "add ': AnyObject'" }

    var fixItID: MessageID {
        MessageID(domain: "DynamicRuntimeMacros", id: "addAnyObject")
    }
}

/// A diagnostic paired with the node it applies to, raised while parsing.
struct ContractError: Error {

    let diagnostics: [Diagnostic]

    init(_ diagnostics: [Diagnostic]) {
        self.diagnostics = diagnostics
    }

    init(_ message: ContractDiagnostic, at node: some SyntaxProtocol) {
        self.diagnostics = [Diagnostic(node: Syntax(node), message: message)]
    }
}
