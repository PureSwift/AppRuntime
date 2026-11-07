/// An error crossing the runtime boundary.
///
/// Contract methods that `throws` throw this type. It is concrete so it can
/// be used with typed throws in Embedded Swift.
public enum RuntimeError: Error, Equatable, Hashable, Sendable {

    /// The class or method doesn't exist on this host.
    case notFound

    /// The wire signature doesn't match the implementation.
    case signature

    /// The implementation threw. Carries the host's error message.
    case thrown(String)

    /// A message was sent to null.
    case null
}

public extension RuntimeError {

    /// The status code reported for this error.
    var status: RuntimeStatus {
        switch self {
        case .notFound: return .notFound
        case .signature: return .signature
        case .thrown: return .thrown
        case .null: return .null
        }
    }

    /// Creates an error from a failed status. Returns `nil` for `.ok`.
    init?(status: RuntimeStatus, message: String = "") {
        switch status {
        case .ok: return nil
        case .notFound: self = .notFound
        case .signature: self = .signature
        case .thrown: self = .thrown(message)
        case .null: self = .null
        }
    }

    /// Message reported through `rt_error_message`, if any.
    var message: String {
        switch self {
        case .notFound: return "not found"
        case .signature: return "signature mismatch"
        case .thrown(let message): return message
        case .null: return "message to null"
        }
    }
}
