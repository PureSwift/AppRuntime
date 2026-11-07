import RuntimeABI

/// Generates the peer declarations for a parsed contract.
///
/// Every expansion is mode-independent: it calls into `DynamicRuntime`,
/// whose `rt_*` calls are wasm imports or C symbols depending on the target.
struct ContractGenerator {

    let model: ContractModel

    var proxy: String { model.proxyName }

    var access: String { model.access }

    // MARK: Proxy

    func proxyDeclaration() -> String {
        var members = [String]()
        members.append(descriptorDeclaration())
        members.append("\(access)static let classReference = ClassReference(\(literal(model.runtimeName)))")
        members.append(methodsDeclaration())
        members.append(contentsOf: model.methods.map(requirement))
        members.append(wrappingDeclarations())
        members.append(instanceDispatch())
        if model.kind == .contract {
            members.append(staticDispatch())
            members.append(registration())
        }
        members.append("""
            /// Registers this interface's descriptor without an implementation.
            \(access)static func registerInterface(in registrar: some ContractRegistrar) {
                registrar.register(descriptor, statics: nil)
            }
            """)
        let kindName = model.kind == .contract ? "contract" : "callback interface"
        return """
            /// Proxy for the `\(model.runtimeName)` \(kindName), generated from `\(model.protocolName)`.
            \(access)final class \(proxy): DynamicObject, \(model.protocolName), DynamicInterface {

            \(members.joined(separator: "\n\n").indented())
            }
            """
    }

    private func descriptorDeclaration() -> String {
        let methods = model.methods.map { method in
            "MethodDescriptor(\(literal(method.key)), \(literal(method.signature.description)), \(kindExpression(method.kind))),"
        }
        let capability = model.capability.map { "Capability(\(literal($0)))" } ?? "nil"
        return """
            \(access)static let descriptor = ContractDescriptor(
                name: \(literal(model.runtimeName)),
                kind: \(model.kind == .contract ? ".contract" : ".callback"),
                version: \(model.version),
                capability: \(capability),
                methods: [
            \(methods.joined(separator: "\n").indented(2))
                ]
            )
            """
    }

    private func methodsDeclaration() -> String {
        let references = model.methods.map { method in
            "\(access)static let \(identifier(method.referenceName)) = MethodReference(\(proxy).classReference, \(literal(method.key)), \(literal(method.signature.description)), \(kindExpression(method.kind)))"
        }
        return """
            /// Lazily resolved methods. `isAvailable` is `false` for methods the host doesn't provide.
            \(access)enum Methods {
            \(references.joined(separator: "\n").indented())
            }
            """
    }

    /// The proxy's implementation of one protocol requirement.
    private func requirement(_ method: ContractMethod) -> String {
        let parameters = method.parameters.map { parameter in
            "\(parameter.label.map(identifier) ?? "_") \(parameter.name): \(parameter.typeText)"
        }.joined(separator: ", ")
        let staticModifier = method.kind == .instance ? "" : "static "
        let effects = method.throwsClause.map { " \($0)" } ?? ""
        let result = method.resultText.map { " -> \($0)" } ?? ""
        let target = method.kind == .instance ? ", target: handle" : ""
        var body = [String]()
        body.append("\(method.parameters.isEmpty ? "let" : "var") call = Call(Methods.\(identifier(method.referenceName))\(target))")
        for parameter in method.parameters {
            body.append(argumentEncoding(parameter.type, parameter.name))
        }
        let invoke = method.isThrowing ? "try call.invoke()" : "call.invokeOrTrap()"
        if let type = method.result {
            body.append("let results = \(invoke)")
            body.append("return \(resultDecoding(type))")
        } else {
            body.append("_ = \(invoke)")
        }
        return """
            \(access)\(staticModifier)func \(identifier(method.baseName))(\(parameters))\(effects)\(result) {
            \(body.joined(separator: "\n").indented())
            }
            """
    }

    private func wrappingDeclarations() -> String {
        """
        /// Wraps a +1 handle. `nil` for null.
        \(access)static func wrap(retained handle: ObjectHandle) -> \(proxy)? {
            handle == 0 ? nil : \(proxy)(retained: handle)
        }

        /// Wraps a borrowed handle, retaining it. `nil` for null.
        \(access)static func wrap(borrowing handle: ObjectHandle) -> \(proxy)? {
            handle == 0 ? nil : \(proxy)(borrowing: handle)
        }

        /// A +1 handle for any implementation: a proxy's own handle, or a new
        /// native object exported with `rt_implement`.
        \(access)static func retainedHandle(for value: any \(model.protocolName)) -> ObjectHandle {
            if let object = value as? DynamicObject {
                return object.retainedHandle
            }
            return export(value)
        }

        /// Exports a Swift implementation as a native object. Returns a +1 handle.
        \(access)static func export(_ value: any \(model.protocolName)) -> ObjectHandle {
            Exported.implement(value, interface: classReference, descriptor: descriptor) { (index: UInt32, target: ObjectHandle, arguments: inout Arguments, results: ResultWriter) throws(RuntimeError) in
                try dispatch(value, index: index, arguments: &arguments, results: results)
            }
        }
        """
    }

    private func instanceDispatch() -> String {
        let cases = model.methods.filter { $0.kind == .instance }.map { method in
            dispatchCase(method, receiver: "target", resultIsSelf: false)
        }
        return """
            /// Routes an incoming call to an exported implementation. `index` is the
            /// position among the instance methods.
            \(access)static func dispatch(_ target: any \(model.protocolName), index: UInt32, arguments: inout Arguments, results: ResultWriter) throws(RuntimeError) {
                switch index {
            \(cases.joined(separator: "\n"))
                default:
                    throw RuntimeError.notFound
                }
            }
            """
    }

    private func staticDispatch() -> String {
        let cases = model.methods.filter { $0.kind != .instance }.map { method in
            dispatchCase(method, receiver: "type", resultIsSelf: method.kind == .constructor)
        }
        return """
            /// Routes a static or constructor call to `type`. `index` is the position
            /// among the static and constructor methods.
            \(access)static func dispatchStatic<T: \(model.protocolName)>(_ type: T.Type, index: UInt32, arguments: inout Arguments, results: ResultWriter) throws(RuntimeError) {
                switch index {
            \(cases.joined(separator: "\n"))
                default:
                    throw RuntimeError.notFound
                }
            }
            """
    }

    private func dispatchCase(_ method: ContractMethod, receiver: String, resultIsSelf: Bool) -> String {
        var lines = [String]()
        for parameter in method.parameters {
            lines.append("let \(parameter.name) = \(argumentDecoding(parameter.type))")
        }
        let arguments = method.parameters.map { parameter in
            parameter.label.map { "\($0): \(parameter.name)" } ?? parameter.name
        }.joined(separator: ", ")
        var invocation = "\(receiver).\(identifier(method.baseName))(\(arguments))"
        if method.isThrowing {
            invocation = method.isTypedThrows
                ? "try \(invocation)"
                : "try rethrowingRuntimeError { try \(invocation) }"
        }
        if let result = method.result {
            lines.append("let value = \(invocation)")
            if resultIsSelf {
                lines.append(result == .optional(.selfType)
                    ? "results.set(retained: value.map { retainedHandle(for: $0) } ?? 0)"
                    : "results.set(retained: retainedHandle(for: value))")
            } else {
                lines.append(resultEncoding(result, "value"))
            }
        } else {
            lines.append(invocation)
        }
        return """
                case \(method.dispatchIndex):
            \(lines.joined(separator: "\n").indented(2))
            """
    }

    private func registration() -> String {
        """
        /// Registers `type` as this platform's implementation of the contract
        /// with a Swift-registry host.
        \(access)static func register<T: \(model.protocolName)>(_ type: T.Type, in registrar: some ContractRegistrar) {
            registrar.register(descriptor) { (index: UInt32, arguments: inout Arguments, results: ResultWriter) throws(RuntimeError) in
                try dispatchStatic(type, index: index, arguments: &arguments, results: results)
            }
        }
        """
    }

    // MARK: Marshaling

    /// Adds an argument to `call`.
    private func argumentEncoding(_ type: ContractType, _ expression: String) -> String {
        switch type {
        case .object(let name):
            return "call.add(retained: \(name)Proxy.retainedHandle(for: \(expression)))"
        case .optional(.object(let name)):
            return "call.add(retained: \(expression).map { \(name)Proxy.retainedHandle(for: $0) } ?? 0)"
        case .objects(let name), .optional(.objects(let name)):
            return "call.addList(\(expression)) { \(name)Proxy.retainedHandle(for: $0) }"
        default:
            return "call.add(\(expression))"
        }
    }

    /// Reads an owned result from `results`.
    private func resultDecoding(_ type: ContractType) -> String {
        switch type {
        case .scalar(let name, _):
            return "results.scalar(\(name).self)"
        case .string:
            return "results.string()"
        case .bytes:
            return "results.bytes()"
        case .strings:
            return "results.strings()"
        case .object(let name):
            return "\(name)Proxy(retained: results.handle())"
        case .objects(let name):
            return "results.list { (handle: ObjectHandle) -> any \(name) in \(name)Proxy(retained: handle) }"
        case .selfType:
            return "Self(retained: results.handle())"
        case .optional(let wrapped):
            switch wrapped {
            case .string: return "results.optionalString()"
            case .bytes: return "results.optionalBytes()"
            case .strings: return "results.optionalStrings()"
            case .object(let name): return "\(name)Proxy.wrap(retained: results.handle())"
            case .objects(let name):
                return "results.optionalList { (handle: ObjectHandle) -> any \(name) in \(name)Proxy(retained: handle) }"
            case .selfType: return "results.handle() == 0 ? nil : Self(retained: results.handle())"
            default: return "results.handle()"
            }
        }
    }

    /// Reads a borrowed argument from `arguments`.
    private func argumentDecoding(_ type: ContractType) -> String {
        switch type {
        case .scalar(let name, _):
            return "arguments.scalar(\(name).self)"
        case .string:
            return "arguments.string()"
        case .bytes:
            return "arguments.bytes()"
        case .strings:
            return "arguments.strings()"
        case .object(let name):
            return "\(name)Proxy(borrowing: arguments.handle())"
        case .objects(let name):
            return "arguments.list { (handle: ObjectHandle) -> any \(name) in \(name)Proxy(retained: handle) }"
        case .selfType:
            return "arguments.handle()"
        case .optional(let wrapped):
            switch wrapped {
            case .string: return "arguments.optionalString()"
            case .bytes: return "arguments.optionalBytes()"
            case .strings: return "arguments.optionalStrings()"
            case .object(let name): return "\(name)Proxy.wrap(borrowing: arguments.handle())"
            case .objects(let name):
                return "arguments.optionalList { (handle: ObjectHandle) -> any \(name) in \(name)Proxy(retained: handle) }"
            default: return "arguments.handle()"
            }
        }
    }

    /// Writes a +1 result to `results`.
    private func resultEncoding(_ type: ContractType, _ expression: String) -> String {
        switch type {
        case .object(let name):
            return "results.set(retained: \(name)Proxy.retainedHandle(for: \(expression)))"
        case .optional(.object(let name)):
            return "results.set(retained: \(expression).map { \(name)Proxy.retainedHandle(for: $0) } ?? 0)"
        case .objects(let name), .optional(.objects(let name)):
            return "results.setList(\(expression)) { \(name)Proxy.retainedHandle(for: $0) }"
        case .selfType:
            return "results.set(retained: retainedHandle(for: \(expression)))"
        default:
            return "results.set(\(expression))"
        }
    }

    // MARK: Metadata

    /// The contract's `rt.contracts` record, placed in the object-file section
    /// for the target's object format (§10), so bare-metal Mach-O and ELF
    /// triples get the right section name too. `@export(interface)` keeps Embedded Swift from
    /// re-emitting the record into every module that imports the contract.
    func metadataDeclaration() -> String {
        let bytes = ContractMetadata.encode(model.descriptor)
        let name = "_rt_contract_\(model.protocolName)"
        let type = "(" + Array(repeating: "UInt8", count: bytes.count).joined(separator: ", ") + ")"
        let rows = stride(from: 0, to: bytes.count, by: 16).map { start in
            bytes[start..<min(start + 16, bytes.count)].map { hex($0) }.joined(separator: ", ")
        }
        let value = "(\n" + rows.joined(separator: ",\n").indented() + "\n)"
        func declaration(_ section: String) -> String {
            """
            @used @export(interface) @section(\(literal(section)))
            internal let \(name): \(type) = \(value)
            """
        }
        return """
            #if objectFormat(MachO)
            \(declaration("__DATA,__rt_contracts"))
            #elseif objectFormat(Wasm)
            \(declaration("rt.contracts"))
            #else
            \(declaration(".rt_contracts"))
            #endif
            """
    }

    // MARK: Helpers

    private func literal(_ string: String) -> String {
        var escaped = ""
        for character in string {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private func identifier(_ name: String) -> String {
        "`\(name)`"
    }

    private func kindExpression(_ kind: MethodKind) -> String {
        switch kind {
        case .instance: return ".instance"
        case .static: return ".static"
        case .constructor: return ".constructor"
        }
    }

    private func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return "0x" + String(digits[Int(byte >> 4)]) + String(digits[Int(byte & 0xF)])
    }
}

extension String {

    /// Indents every non-empty line by `levels` × 4 spaces.
    func indented(_ levels: Int = 1) -> String {
        let indentation = String(repeating: " ", count: levels * 4)
        return split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : indentation + $0 }
            .joined(separator: "\n")
    }
}
