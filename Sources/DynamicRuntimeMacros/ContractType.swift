import RuntimeABI
import SwiftSyntax

/// A Swift type allowed in a contract signature, and how it travels.
indirect enum ContractType: Equatable {

    /// `Bool`, `Int32`, `Int64`, `Float`, `Double`.
    case scalar(name: String, wire: WireType)

    /// `String`, as a host string object.
    case string

    /// `[UInt8]`, as a host byte buffer.
    case bytes

    /// A named object type: another contract or callback protocol, or a
    /// `RawRepresentable` type with `String` raw values. Syntax can't tell
    /// them apart; the compiler picks the marshaling overload.
    case object(protocolName: String)

    /// `[String]`, as a `List` of strings.
    case strings

    /// `[SomeContract]` or `[RawStringType]`, as a `List` of objects.
    case objects(protocolName: String)

    /// `T?` of an object type.
    case optional(ContractType)

    /// `Self`, only as a constructor's result.
    case selfType

    var wireType: WireType {
        switch self {
        case .scalar(_, let wire): return wire
        default: return .object
        }
    }

    /// Whether `nil` can be represented: every object type can.
    var isObjectType: Bool {
        if case .scalar = self { return false }
        return true
    }
}

extension ContractType {

    /// Parses a type, or explains why it can't cross the boundary.
    static func parse(_ type: TypeSyntax) throws(ContractError) -> ContractType {
        let parsed = try parseUnchecked(type)
        if case .optional(let wrapped) = parsed {
            // `Self?` is a failable constructor's result.
            guard wrapped.isObjectType else {
                throw ContractError(
                    .unsupportedType(type.trimmedDescription, hint: "only object types (String, [UInt8], arrays, contracts) can be optional"),
                    at: type
                )
            }
            if case .optional = wrapped {
                throw ContractError(.unsupportedType(type.trimmedDescription, hint: "nested optionals aren't allowed"), at: type)
            }
        }
        return parsed
    }

    private static func parseUnchecked(_ type: TypeSyntax) throws(ContractError) -> ContractType {
        if isBytes(type) {
            return .bytes
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return .optional(try parse(optional.wrappedType))
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return try parseArray(element: array.element, whole: type)
        }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.firstName == nil {
            return try parseUnchecked(element.type)
        }
        if let existential = type.as(SomeOrAnyTypeSyntax.self) {
            guard existential.someOrAnySpecifier.tokenKind == .keyword(.any) else {
                throw ContractError(.unsupportedType(type.trimmedDescription, hint: "use 'any' or the bare protocol name"), at: type)
            }
            guard let name = simpleName(existential.constraint) else {
                throw ContractError(.unsupportedType(type.trimmedDescription, hint: nil), at: type)
            }
            return .object(protocolName: name)
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
           let arguments = identifier.genericArgumentClause?.arguments,
           arguments.count == 1,
           let argument = arguments.first?.argument.as(TypeSyntax.self) {
            switch identifier.name.text {
            case "Optional":
                return .optional(try parse(argument))
            case "Array":
                return try parseArray(element: argument, whole: type)
            default:
                throw ContractError(.unsupportedType(type.trimmedDescription, hint: "generic types aren't allowed"), at: type)
            }
        }
        guard let name = simpleName(type) else {
            throw ContractError(.unsupportedType(type.trimmedDescription, hint: nil), at: type)
        }
        switch name {
        case "Bool": return .scalar(name: name, wire: .bool)
        case "Int32": return .scalar(name: name, wire: .int32)
        case "Int64": return .scalar(name: name, wire: .int64)
        case "Float", "Float32": return .scalar(name: "Float", wire: .float32)
        case "Double", "Float64": return .scalar(name: "Double", wire: .float64)
        case "String": return .string
        case "Self": return .selfType
        case "Int", "UInt":
            throw ContractError(.unsupportedType(name, hint: "use Int32 or Int64, since Int is 32 bits on wasm32 and 64 bits on arm64"), at: type)
        case "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64", "Character":
            throw ContractError(.unsupportedType(name, hint: "unsigned and narrow integers aren't wire types (Java has no unsigned); use Int32 or Int64"), at: type)
        case "Void":
            throw ContractError(.unsupportedType(name, hint: "omit the return type instead"), at: type)
        default:
            guard name.first?.isUppercase == true else {
                throw ContractError(.unsupportedType(name, hint: nil), at: type)
            }
            // Another @DynamicRuntime or @DynamicCallback protocol, or a
            // RawRepresentable string type. If it's neither, the compiler
            // reports that no `_rtEncode` overload matches.
            return .object(protocolName: name)
        }
    }

    private static func parseArray(element: TypeSyntax, whole: TypeSyntax) throws(ContractError) -> ContractType {
        switch try parseUnchecked(element) {
        case .scalar(_, _):
            throw ContractError(
                .unsupportedType(whole.trimmedDescription, hint: "arrays may hold String or object types only"),
                at: whole
            )
        case .string:
            return .strings
        case .object(let name):
            return .objects(protocolName: name)
        case .bytes, .strings, .objects, .optional, .selfType:
            throw ContractError(
                .unsupportedType(whole.trimmedDescription, hint: "arrays may hold String or object types only"),
                at: whole
            )
        }
    }

    private static func simpleName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            // `Swift.Int32` and `Module.Contract`.
            return member.name.text
        }
        return nil
    }
}

extension ContractType {

    /// Whether a type spells `[UInt8]` or `Array<UInt8>`.
    fileprivate static func isBytes(_ type: TypeSyntax) -> Bool {
        let element: TypeSyntax
        if let array = type.as(ArrayTypeSyntax.self) {
            element = array.element
        } else if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Array",
                  let argument = identifier.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self) {
            element = argument
        } else {
            return false
        }
        let name = element.trimmedDescription
        return name == "UInt8" || name == "Swift.UInt8"
    }
}
