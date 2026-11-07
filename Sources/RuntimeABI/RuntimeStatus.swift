/// Status code returned by every fallible call (`rt_status`).
public enum RuntimeStatus: UInt32, Equatable, Hashable, Sendable {

    /// `RT_OK`
    case ok = 0

    /// `RT_ERR_NOT_FOUND`: class or method missing on this platform or OS.
    case notFound = 1

    /// `RT_ERR_SIGNATURE`: wire signature does not fit the native signature.
    case signature = 2

    /// `RT_ERR_THROWN`: the implementation threw; see `rt_error_message`.
    case thrown = 3

    /// `RT_ERR_NULL`: message to null where the backend forbids it.
    case null = 4
}

public extension RuntimeStatus {

    /// Converts an unknown raw value to `.thrown`.
    init(code: UInt32) {
        self = RuntimeStatus(rawValue: code) ?? .thrown
    }
}
