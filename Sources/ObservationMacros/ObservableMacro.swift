import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// An error a macro reports at its attribute.
struct ObservationMacroError: Error, CustomStringConvertible {
    let description: String
}

/// The stored properties `@Observable` tracks, in declaration order: `var`s
/// with a single name, no accessors, not `static`, `lazy` or
/// `@ObservationIgnored`. A property's index is its position here.
struct TrackedProperty {
    let name: String
    let type: String?
    let declaration: VariableDeclSyntax
}

extension DeclGroupSyntax {

    var trackedProperties: [TrackedProperty] {
        memberBlock.members.compactMap { member in
            member.decl.as(VariableDeclSyntax.self).flatMap(TrackedProperty.init)
        }
    }
}

extension TrackedProperty {

    init?(_ declaration: VariableDeclSyntax) {
        guard declaration.bindingSpecifier.tokenKind == .keyword(.var),
              declaration.bindings.count == 1,
              let binding = declaration.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.accessorBlock == nil,
              !declaration.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }),
              !declaration.hasAttribute("ObservationIgnored"),
              !declaration.hasAttribute("ObservationTracked") else {
            return nil
        }
        self.name = pattern.identifier.text
        self.type = binding.typeAnnotation?.type.trimmedDescription
        self.declaration = declaration
    }
}

extension VariableDeclSyntax {

    func hasAttribute(_ name: String) -> Bool {
        attributes.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
    }
}

/// `@Observable` (§5.3): the registrar, index-based `access` and
/// `withMutation`, `@ObservationTracked(index:)` on each tracked property,
/// the `Bindings` that `@Bindable` uses, and the `Observable` conformance.
public struct ObservableMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {

    // MARK: MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw ObservationMacroError(description: "@Observable applies to classes")
        }
        let access = classDecl.modifiers.contains { ["public", "open"].contains($0.name.text) } ? "public " : ""
        let className = classDecl.name.text
        let bindings = classDecl.trackedProperties.compactMap { property -> String? in
            // A binding needs the property's type, which only an annotation gives.
            guard let type = property.type else { return nil }
            return """
                \(access)var \(property.name): Binding<\(type)> {
                    let model = _model
                    return Binding(get: { model.\(property.name) }, set: { model.\(property.name) = $0 })
                }
            """
        }
        return [
            "@ObservationIgnored private let _$observationRegistrar = ObservationRegistrar()",
            """
            internal nonisolated func access(propertyIndex: Int) {
                _$observationRegistrar.access(self, propertyIndex: propertyIndex)
            }
            """,
            """
            internal nonisolated func withMutation<_Result, _Failure: Error>(
                propertyIndex: Int,
                _ mutation: () throws(_Failure) -> _Result
            ) throws(_Failure) -> _Result {
                try _$observationRegistrar.withMutation(of: self, propertyIndex: propertyIndex, mutation)
            }
            """,
            """
            /// One `Binding` per stored property with a type annotation, for `$model.name`.
            \(raw: access)struct Bindings {
                let _model: \(raw: className)
            \(raw: bindings.joined(separator: "\n"))
            }
            """,
            """
            \(raw: access)var _$bindings: Bindings {
                Bindings(_model: self)
            }
            """,
        ]
    }

    // MARK: MemberAttributeMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        // Matched by name: the member may be a different syntax node from
        // the one in `declaration`.
        guard let variable = member.as(VariableDeclSyntax.self),
              let property = TrackedProperty(variable),
              let index = declaration.trackedProperties.firstIndex(where: { $0.name == property.name }) else {
            return []
        }
        return ["@ObservationTracked(index: \(raw: index))"]
    }

    // MARK: ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self), !protocols.isEmpty else { return [] }
        let conformances = protocols.map { $0.trimmedDescription }.joined(separator: ", ")
        let decl: DeclSyntax = "extension \(type.trimmed): \(raw: conformances) {}"
        return decl.as(ExtensionDeclSyntax.self).map { [$0] } ?? []
    }
}

/// `@ObservationTracked(index:)`: turns a stored property into accessors
/// over `_name` storage, reading through `access(propertyIndex:)` and
/// writing through `withMutation(propertyIndex:_:)`.
public struct ObservationTrackedMacro: AccessorMacro, PeerMacro {

    static func index(_ node: AttributeSyntax) throws -> Int {
        guard case .argumentList(let arguments) = node.arguments,
              let literal = arguments.first?.expression.as(IntegerLiteralExprSyntax.self),
              let index = Int(literal.literal.text) else {
            throw ObservationMacroError(description: "@ObservationTracked needs an integer index")
        }
        return index
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            return []
        }
        let index = try index(node)
        return [
            """
            @storageRestrictions(initializes: _\(raw: name))
            init(initialValue) {
                _\(raw: name) = initialValue
            }
            """,
            """
            get {
                access(propertyIndex: \(raw: index))
                return _\(raw: name)
            }
            """,
            """
            set {
                withMutation(propertyIndex: \(raw: index)) {
                    _\(raw: name) = newValue
                }
            }
            """,
            """
            _modify {
                access(propertyIndex: \(raw: index))
                _$observationRegistrar.willSet(self, propertyIndex: \(raw: index))
                defer {
                    _$observationRegistrar.didSet(self, propertyIndex: \(raw: index))
                }
                yield &_\(raw: name)
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            return []
        }
        let type = binding.typeAnnotation.map { $0.trimmedDescription } ?? ""
        let initializer = binding.initializer.map { " " + $0.trimmedDescription } ?? ""
        return ["@ObservationIgnored private var _\(raw: name)\(raw: type)\(raw: initializer)"]
    }
}

/// `@ObservationIgnored`: a marker; the property stays a plain stored property.
public struct ObservationIgnoredMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
