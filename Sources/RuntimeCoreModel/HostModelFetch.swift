import CoreModel
import DynamicCoreModel
import DynamicRuntime

/// A fetch request as the guest builds it: the `ModelFetch` contract,
/// building a CoreModel `FetchRequest`.
public final class HostModelFetch: ModelFetch {

    let entity: String

    private var predicate: HostModelPredicate?

    private var sorts: [(keyPath: String, ascending: Bool)] = []

    private var limit: Int32 = 0

    private var offset: Int32 = 0

    private var ids: [String]?

    init(entity: String) {
        self.entity = entity
    }

    public static func make(_ entity: String) -> HostModelFetch {
        HostModelFetch(entity: entity)
    }

    public func setPredicate(_ predicate: (any ModelPredicate)?) {
        guard let predicate else {
            self.predicate = nil
            return
        }
        // One from somewhere else can't be read: it fails the fetch.
        self.predicate = HostModelStoreModule.host(predicate, as: HostModelPredicate.self) ?? HostModelPredicate(nil)
    }

    public func addSort(_ keyPath: String, ascending: Bool) {
        sorts.append((keyPath, ascending))
    }

    public func setLimit(_ limit: Int32) {
        self.limit = limit
    }

    public func setOffset(_ offset: Int32) {
        self.offset = offset
    }

    public func setIDs(_ ids: [String]) {
        self.ids = ids
    }

    /// What to fetch, as it stands now.
    struct Request: Sendable {

        var request: FetchRequest

        /// Only the objects with these IDs.
        var ids: [ObjectID]?
    }

    /// The request, checked against `model`, or what's wrong with it.
    func request(in model: Model) -> Result<Request, ModelStoreError> {
        func invalid(_ message: String) -> Result<Request, ModelStoreError> {
            .failure(ModelStoreError(.invalidRequest, message: message))
        }
        guard !entity.isEmpty, let description = model[EntityName(rawValue: entity)] else {
            return invalid("no entity \"\(entity)\"")
        }
        guard limit >= 0, offset >= 0 else {
            return invalid("a negative limit or offset")
        }
        var request = FetchRequest(entity: description.id, fetchLimit: Int(limit), fetchOffset: Int(offset))
        for sort in sorts {
            guard !sort.keyPath.isEmpty, description[attribute: PropertyKey(rawValue: sort.keyPath)] != nil else {
                return invalid("\(entity) has no attribute \"\(sort.keyPath)\" to sort by")
            }
            request.sortDescriptors.append(.init(property: PropertyKey(rawValue: sort.keyPath), ascending: sort.ascending))
        }
        if let predicate {
            guard let value = predicate.value else {
                return invalid("a predicate that can't be read")
            }
            for keyPath in value.keyPaths {
                guard case .property(let name)? = keyPath.keys.first, !name.isEmpty,
                      description[attribute: PropertyKey(rawValue: name)] != nil || description[relationship: PropertyKey(rawValue: name)] != nil else {
                    return invalid("\(entity) has no property for the key path \"\(keyPath.rawValue)\"")
                }
            }
            request.predicate = value
        }
        return .success(Request(request: request, ids: ids.map { $0.map { ObjectID(rawValue: $0) } }))
    }
}

/// A predicate: the `ModelPredicate` contract, holding CoreModel's.
public final class HostModelPredicate: ModelPredicate {

    /// `nil` when something in it couldn't be read.
    let value: FetchRequest.Predicate?

    init(_ value: FetchRequest.Predicate?) {
        self.value = value
    }

    public static func comparison(_ left: any ModelExpression, operation: Int32, right: any ModelExpression, modifier: Int32, options: Int32) -> HostModelPredicate {
        guard let left = HostModelStoreModule.host(left, as: HostModelExpression.self)?.value,
              let right = HostModelStoreModule.host(right, as: HostModelExpression.self)?.value,
              let operation = ModelComparison(rawValue: operation),
              let modifier = ModelComparisonModifier(rawValue: modifier),
              options >= 0, options < 16 else {
            return HostModelPredicate(nil)
        }
        return HostModelPredicate(.comparison(.init(
            left: left,
            right: right,
            type: operation.operation,
            modifier: modifier.modifier,
            options: ModelComparisonOptions(rawValue: options).options
        )))
    }

    private static func values(_ predicates: [any ModelPredicate]) -> [FetchRequest.Predicate]? {
        var values = [FetchRequest.Predicate]()
        for predicate in predicates {
            guard let value = HostModelStoreModule.host(predicate, as: HostModelPredicate.self)?.value else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    public static func and(_ predicates: [any ModelPredicate]) -> HostModelPredicate {
        HostModelPredicate(values(predicates).map { .compound(.and($0)) })
    }

    public static func or(_ predicates: [any ModelPredicate]) -> HostModelPredicate {
        HostModelPredicate(values(predicates).map { .compound(.or($0)) })
    }

    public static func not(_ predicate: any ModelPredicate) -> HostModelPredicate {
        HostModelPredicate(HostModelStoreModule.host(predicate, as: HostModelPredicate.self)?.value.map { .compound(.not($0)) })
    }

    public static func constant(_ value: Bool) -> HostModelPredicate {
        HostModelPredicate(.value(value))
    }
}

/// One side of a comparison: the `ModelExpression` contract, holding
/// CoreModel's.
public final class HostModelExpression: ModelExpression {

    /// `nil` when it couldn't be read: a value that isn't of its type.
    let value: FetchRequest.Predicate.Expression?

    init(_ value: FetchRequest.Predicate.Expression?) {
        self.value = value
    }

    private static func constant(_ value: ModelValue, type: Int32, kind: ModelValue.Kind) -> HostModelExpression {
        guard let type = ModelAttributeType(rawValue: type), type.kind == kind,
              let attribute = value.attributeValue(as: type) else {
            return HostModelExpression(nil)
        }
        return HostModelExpression(.attribute(attribute))
    }

    public static func keyPath(_ path: String) -> HostModelExpression {
        // CoreModel reads each component as a name; an empty one has none.
        guard !path.isEmpty, !path.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) else {
            return HostModelExpression(nil)
        }
        return HostModelExpression(.keyPath(PredicateKeyPath(rawValue: path)))
    }

    public static func null() -> HostModelExpression {
        HostModelExpression(.attribute(.null))
    }

    public static func bool(_ value: Bool) -> HostModelExpression {
        HostModelExpression(.attribute(.bool(value)))
    }

    public static func integer(_ value: Int64, type: Int32) -> HostModelExpression {
        constant(.integer(value), type: type, kind: .integer)
    }

    public static func double(_ value: Double, type: Int32) -> HostModelExpression {
        constant(.double(value), type: type, kind: .double)
    }

    public static func string(_ value: String, type: Int32) -> HostModelExpression {
        constant(.string(value), type: type, kind: .string)
    }

    public static func data(_ value: [UInt8]) -> HostModelExpression {
        constant(.data(value), type: ModelAttributeType.data.rawValue, kind: .data)
    }

    public static func toOne(_ id: String) -> HostModelExpression {
        HostModelExpression(.relationship(.toOne(ObjectID(rawValue: id))))
    }

    public static func toMany(_ ids: [String]) -> HostModelExpression {
        HostModelExpression(.relationship(.toMany(ids.map { ObjectID(rawValue: $0) })))
    }

    public static func arithmetic(_ left: any ModelExpression, operation: Int32, right: any ModelExpression) -> HostModelExpression {
        guard let left = HostModelStoreModule.host(left, as: HostModelExpression.self)?.value,
              let right = HostModelStoreModule.host(right, as: HostModelExpression.self)?.value,
              let operation = ModelArithmetic(rawValue: operation) else {
            return HostModelExpression(nil)
        }
        return HostModelExpression(.arithmetic(.init(function: operation.function, left: left, right: right)))
    }
}

extension FetchRequest.Predicate {

    /// Every key path the predicate reads.
    var keyPaths: [PredicateKeyPath] {
        switch self {
        case .value:
            return []
        case .comparison(let comparison):
            return comparison.left.keyPaths + comparison.right.keyPaths
        case .compound(.and(let predicates)), .compound(.or(let predicates)):
            return predicates.flatMap { $0.keyPaths }
        case .compound(.not(let predicate)):
            return predicate.keyPaths
        }
    }
}

extension FetchRequest.Predicate.Expression {

    var keyPaths: [PredicateKeyPath] {
        switch self {
        case .keyPath(let keyPath):
            return [keyPath]
        case .arithmetic(let arithmetic):
            return arithmetic.left.keyPaths + arithmetic.right.keyPaths
        case .function(let function):
            return function.arguments.flatMap { $0.keyPaths }
        case .attribute, .relationship:
            return []
        }
    }
}
