import CoreModel
import DynamicRuntime

// A CoreModel fetch request, as the host's objects.

extension FetchRequest {

    /// Whether the request calls a custom function, which only the guest
    /// can run.
    var usesFunctions: Bool {
        for descriptor in sortDescriptors {
            if case .function = descriptor.term {
                return true
            }
        }
        return predicate?.usesFunctions ?? false
    }

    /// The host's fetch for this request.
    func makeFetch() throws(ModelStoreError) -> any ModelFetch {
        let fetch = ModelFetchProxy.make(entity.rawValue)
        if let predicate {
            fetch.setPredicate(try predicate.makePredicate())
        }
        for descriptor in sortDescriptors {
            guard case .property(let key) = descriptor.term else {
                throw ModelStoreError(.unsupported, message: "a sort by a function")
            }
            fetch.addSort(key.rawValue, ascending: descriptor.ascending)
        }
        if fetchLimit > 0 {
            fetch.setLimit(Int32(clamping: fetchLimit))
        }
        if fetchOffset > 0 {
            fetch.setOffset(Int32(clamping: fetchOffset))
        }
        return fetch
    }
}

extension FetchRequest.Predicate {

    var usesFunctions: Bool {
        switch self {
        case .value:
            return false
        case .comparison(let comparison):
            return comparison.left.usesFunctions || comparison.right.usesFunctions
        case .compound(.and(let predicates)), .compound(.or(let predicates)):
            return predicates.contains { $0.usesFunctions }
        case .compound(.not(let predicate)):
            return predicate.usesFunctions
        }
    }

    func makePredicate() throws(ModelStoreError) -> any ModelPredicate {
        switch self {
        case .value(let value):
            return ModelPredicateProxy.constant(value)
        case .comparison(let comparison):
            return ModelPredicateProxy.comparison(
                try comparison.left.makeExpression(),
                operation: ModelComparison(comparison.type).rawValue,
                right: try comparison.right.makeExpression(),
                modifier: ModelComparisonModifier(comparison.modifier).rawValue,
                options: ModelComparisonOptions(comparison.options).rawValue
            )
        case .compound(.and(let predicates)):
            return ModelPredicateProxy.and(try Self.makePredicates(predicates))
        case .compound(.or(let predicates)):
            return ModelPredicateProxy.or(try Self.makePredicates(predicates))
        case .compound(.not(let predicate)):
            return ModelPredicateProxy.not(try predicate.makePredicate())
        }
    }

    private static func makePredicates(_ predicates: [FetchRequest.Predicate]) throws(ModelStoreError) -> [any ModelPredicate] {
        var made = [any ModelPredicate]()
        for predicate in predicates {
            made.append(try predicate.makePredicate())
        }
        return made
    }

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

    var usesFunctions: Bool {
        switch self {
        case .function:
            return true
        case .arithmetic(let arithmetic):
            return arithmetic.left.usesFunctions || arithmetic.right.usesFunctions
        case .attribute, .relationship, .keyPath:
            return false
        }
    }

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

    func makeExpression() throws(ModelStoreError) -> any ModelExpression {
        switch self {
        case .keyPath(let keyPath):
            return ModelExpressionProxy.keyPath(keyPath.rawValue)
        case .attribute(let value):
            guard let crossing = ModelValue.crossing(value) else {
                throw ModelStoreError(.unsupported, message: "a composite value in a predicate")
            }
            let type = (crossing.type ?? .string).rawValue
            switch crossing.value {
            case .null: return ModelExpressionProxy.null()
            case .bool(let value): return ModelExpressionProxy.bool(value)
            case .integer(let value): return ModelExpressionProxy.integer(value, type: type)
            case .double(let value): return ModelExpressionProxy.double(value, type: type)
            case .string(let value): return ModelExpressionProxy.string(value, type: type)
            case .data(let value): return ModelExpressionProxy.data(value)
            }
        case .relationship(.null):
            return ModelExpressionProxy.null()
        case .relationship(.toOne(let id)):
            return ModelExpressionProxy.toOne(id.rawValue)
        case .relationship(.toMany(let ids)):
            return ModelExpressionProxy.toMany(ids.map { $0.rawValue })
        case .arithmetic(let arithmetic):
            return ModelExpressionProxy.arithmetic(
                try arithmetic.left.makeExpression(),
                operation: ModelArithmetic(arithmetic.function).rawValue,
                right: try arithmetic.right.makeExpression()
            )
        case .function:
            throw ModelStoreError(.unsupported, message: "a function in a predicate")
        }
    }
}
