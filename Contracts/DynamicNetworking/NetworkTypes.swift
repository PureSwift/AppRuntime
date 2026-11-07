/// Guest-side names for the integer codes the Networking contracts carry.

/// `HTTPTask.state()`.
public enum HTTPTaskState: Int32, Sendable {
    case running = 0
    case completed = 1
    case cancelled = 2
    case failed = 3
}

/// `HTTPTaskDelegate.didComplete` codes. `0` is success.
public enum NetworkError: Int32, Error, Sendable {
    case unknown = 1
    case cancelled = 2
    case invalidURL = 3
    case timedOut = 4
    case cannotFindHost = 5
    case cannotConnect = 6
    case connectionLost = 7
    case notConnectedToInternet = 8
    case secureConnectionFailed = 9
    case tooManyRedirects = 10
    case badServerResponse = 11
}
