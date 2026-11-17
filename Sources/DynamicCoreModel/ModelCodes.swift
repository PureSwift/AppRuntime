import CoreModel
#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#elseif canImport(FoundationEmbedded)
// A guest's: CoreModel's `Date`, `UUID`, `URL`, `Decimal` and `Data`.
import FoundationEmbedded
#endif

/// An attribute's type, as the contracts pass it: CoreModel's
/// `AttributeType` without composites, which a store doesn't keep yet.
public enum ModelAttributeType: Int32, CaseIterable, Sendable {

    case bool = 0
    case int16 = 1
    case int32 = 2
    case int64 = 3
    case float = 4
    case double = 5
    case string = 6
    case data = 7
    /// Seconds since 1970 UTC, as a double.
    case date = 8
    /// Lowercase and hyphenated, as a string.
    case uuid = 9
    case url = 10
    /// Its description, as a string.
    case decimal = 11

    /// `nil` for a composite.
    public init?(_ type: AttributeType) {
        switch type {
        case .bool: self = .bool
        case .int16: self = .int16
        case .int32: self = .int32
        case .int64: self = .int64
        case .float: self = .float
        case .double: self = .double
        case .string: self = .string
        case .data: self = .data
        case .date: self = .date
        case .uuid: self = .uuid
        case .url: self = .url
        case .decimal: self = .decimal
        case .composite: return nil
        }
    }

    public var attributeType: AttributeType {
        switch self {
        case .bool: return .bool
        case .int16: return .int16
        case .int32: return .int32
        case .int64: return .int64
        case .float: return .float
        case .double: return .double
        case .string: return .string
        case .data: return .data
        case .date: return .date
        case .uuid: return .uuid
        case .url: return .url
        case .decimal: return .decimal
        }
    }

    /// Which of a record's getters and setters, and which expression
    /// constant, carries a value of this type.
    public var kind: ModelValue.Kind {
        switch self {
        case .bool: return .bool
        case .int16, .int32, .int64: return .integer
        case .float, .double, .date: return .double
        case .string, .uuid, .url, .decimal: return .string
        case .data: return .data
        }
    }
}

/// An attribute's value as it crosses the boundary: one of five kinds,
/// with the attribute's type beside it to say what it stands for.
public enum ModelValue: Equatable, Sendable {

    public enum Kind: Sendable {
        case bool, integer, double, string, data
    }

    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case data([UInt8])

    /// What `value` crosses as, and its type. `nil` for a composite; a
    /// `null` has no type.
    public static func crossing(_ value: AttributeValue) -> (value: ModelValue, type: ModelAttributeType?)? {
        switch value {
        case .null: return (.null, nil)
        case .bool(let value): return (.bool(value), .bool)
        case .int16(let value): return (.integer(Int64(value)), .int16)
        case .int32(let value): return (.integer(Int64(value)), .int32)
        case .int64(let value): return (.integer(value), .int64)
        case .float(let value): return (.double(Double(value)), .float)
        case .double(let value): return (.double(value), .double)
        case .date(let value): return (.double(value.timeIntervalSince1970), .date)
        case .string(let value): return (.string(value), .string)
        case .uuid(let value): return (.string(lowercase(value.uuidString)), .uuid)
        case .url(let value): return (.string(value.absoluteString), .url)
        case .decimal(let value): return (.string(value.description), .decimal)
        case .data(let value): return (.data([UInt8](value)), .data)
        case .composite: return nil
        }
    }

    /// The attribute value this stands for, as `type`. `nil` when it's the
    /// wrong kind for the type, a number that doesn't fit it, or text that
    /// doesn't read as it.
    public func attributeValue(as type: ModelAttributeType) -> AttributeValue? {
        switch (self, type) {
        case (.null, _): return .null
        case (.bool(let value), .bool): return .bool(value)
        case (.integer(let value), .int16): return Int16(exactly: value).map { .int16($0) }
        case (.integer(let value), .int32): return Int32(exactly: value).map { .int32($0) }
        case (.integer(let value), .int64): return .int64(value)
        case (.double(let value), .float): return .float(Float(value))
        case (.double(let value), .double): return .double(value)
        case (.double(let value), .date): return .date(Date(timeIntervalSince1970: value))
        case (.string(let value), .string): return .string(value)
        case (.string(let value), .uuid): return UUID(uuidString: value).map { .uuid($0) }
        case (.string(let value), .url): return URL(string: value).map { .url($0) }
        case (.string(let value), .decimal): return Decimal(string: value).map { .decimal($0) }
        case (.data(let value), .data): return .data(Data(value))
        default: return nil
        }
    }

    /// ASCII letters only, which is all a UUID has; `lowercased()` would
    /// bring in Unicode tables a guest doesn't need.
    static func lowercase(_ text: String) -> String {
        String(decoding: text.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

/// A comparison's operator: CoreModel's
/// `FetchRequest.Predicate.Comparison.Operator`.
public enum ModelComparison: Int32, CaseIterable, Sendable {

    case lessThan = 0
    case lessThanOrEqualTo = 1
    case greaterThan = 2
    case greaterThanOrEqualTo = 3
    case equalTo = 4
    case notEqualTo = 5
    case matches = 6
    case like = 7
    case beginsWith = 8
    case endsWith = 9
    case `in` = 10
    case contains = 11
    case between = 12

    public init(_ operation: FetchRequest.Predicate.Comparison.Operator) {
        switch operation {
        case .lessThan: self = .lessThan
        case .lessThanOrEqualTo: self = .lessThanOrEqualTo
        case .greaterThan: self = .greaterThan
        case .greaterThanOrEqualTo: self = .greaterThanOrEqualTo
        case .equalTo: self = .equalTo
        case .notEqualTo: self = .notEqualTo
        case .matches: self = .matches
        case .like: self = .like
        case .beginsWith: self = .beginsWith
        case .endsWith: self = .endsWith
        case .in: self = .in
        case .contains: self = .contains
        case .between: self = .between
        }
    }

    public var operation: FetchRequest.Predicate.Comparison.Operator {
        switch self {
        case .lessThan: return .lessThan
        case .lessThanOrEqualTo: return .lessThanOrEqualTo
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqualTo: return .greaterThanOrEqualTo
        case .equalTo: return .equalTo
        case .notEqualTo: return .notEqualTo
        case .matches: return .matches
        case .like: return .like
        case .beginsWith: return .beginsWith
        case .endsWith: return .endsWith
        case .in: return .in
        case .contains: return .contains
        case .between: return .between
        }
    }
}

/// `ANY` or `ALL`, for a comparison whose left side is a to-many
/// relationship or goes through one.
public enum ModelComparisonModifier: Int32, CaseIterable, Sendable {

    case none = 0
    case all = 1
    case any = 2

    public init(_ modifier: FetchRequest.Predicate.Comparison.Modifier?) {
        switch modifier {
        case nil: self = .none
        case .all?: self = .all
        case .any?: self = .any
        }
    }

    public var modifier: FetchRequest.Predicate.Comparison.Modifier? {
        switch self {
        case .none: return nil
        case .all: return .all
        case .any: return .any
        }
    }
}

/// A string comparison's options: `[c]`, `[d]` and the rest.
public struct ModelComparisonOptions: OptionSet, Sendable {

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let caseInsensitive = ModelComparisonOptions(rawValue: 1)
    public static let diacriticInsensitive = ModelComparisonOptions(rawValue: 2)
    public static let normalized = ModelComparisonOptions(rawValue: 4)
    public static let localeSensitive = ModelComparisonOptions(rawValue: 8)

    public init(_ options: Set<FetchRequest.Predicate.Comparison.Option>) {
        var value = ModelComparisonOptions()
        for option in options {
            switch option {
            case .caseInsensitive: value.insert(.caseInsensitive)
            case .diacriticInsensitive: value.insert(.diacriticInsensitive)
            case .normalized: value.insert(.normalized)
            case .localeSensitive: value.insert(.localeSensitive)
            }
        }
        self = value
    }

    public var options: Set<FetchRequest.Predicate.Comparison.Option> {
        var options = Set<FetchRequest.Predicate.Comparison.Option>()
        if contains(.caseInsensitive) { options.insert(.caseInsensitive) }
        if contains(.diacriticInsensitive) { options.insert(.diacriticInsensitive) }
        if contains(.normalized) { options.insert(.normalized) }
        if contains(.localeSensitive) { options.insert(.localeSensitive) }
        return options
    }
}

/// An arithmetic expression's function.
public enum ModelArithmetic: Int32, CaseIterable, Sendable {

    case add = 0
    case subtract = 1
    case multiply = 2
    case divide = 3
    case modulus = 4

    public init(_ function: FetchRequest.Predicate.ArithmeticExpression.Function) {
        switch function {
        case .add: self = .add
        case .subtract: self = .subtract
        case .multiply: self = .multiply
        case .divide: self = .divide
        case .modulus: self = .modulus
        }
    }

    public var function: FetchRequest.Predicate.ArithmeticExpression.Function {
        switch self {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .modulus: return .modulus
        }
    }
}

/// What `open` does with a store whose model can't be migrated to the one
/// it's given.
public enum ModelMigration: Int32, Sendable {

    /// `open` fails with `migrationRequired`, and the store is untouched.
    case fail = 0

    /// The store is emptied.
    case reset = 1
}

/// Why a store operation failed.
public struct ModelStoreError: Error, Equatable, Sendable {

    public enum Code: Int32, Sendable {

        case unknown = 0

        /// A cancelled task stopped waiting. The operation isn't undone,
        /// and may still happen. Guest-side only.
        case cancelled = 1

        /// The model contradicts itself, or has what a store doesn't keep:
        /// a relationship to an entity it doesn't have, a composite
        /// attribute.
        case invalidModel = 2

        /// The stored model can't be migrated to the one given.
        case migrationRequired = 3

        /// An entity or key the model doesn't have, or a value of the wrong
        /// type for its attribute.
        case invalidRequest = 4

        /// A request feature this host lacks.
        case unsupported = 5

        case outOfSpace = 6

        /// There's no storage: a private window, a full disk at open.
        case unavailable = 7

        /// The store can't be read.
        case corrupted = 8

        /// A record doesn't decode as the entity asked for. Guest-side
        /// only.
        case undecodable = 9
    }

    public var code: Code

    /// The backend's own description, for logs. Not for showing to users,
    /// and not the same from host to host.
    public var message: String

    public init(_ code: Code, message: String = "") {
        self.code = code
        self.message = message
    }

    /// A code from a newer host is `unknown`.
    public init(rawValue: Int32, message: String = "") {
        self.init(Code(rawValue: rawValue) ?? .unknown, message: message)
    }

    /// Two errors are the same when their codes are: the message is only a
    /// description.
    public static func == (a: ModelStoreError, b: ModelStoreError) -> Bool {
        a.code == b.code
    }
}
