#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A finished request: the final response and the whole body.
public struct HTTPResult: @unchecked Sendable {

    public let response: any HTTPResponse

    public let body: [UInt8]

    public var statusCode: Int32 {
        response.statusCode()
    }
}

/// What a running request reports, in order: progress, the response, body
/// chunks.
public enum HTTPEvent: @unchecked Sendable {

    /// Upload progress.
    case sent(bytes: Int64, total: Int64, expected: Int64)

    /// The final response (after redirects), before its body.
    case response(any HTTPResponse)

    /// The next chunk of the body.
    case data([UInt8])

    /// The host is waiting for a network connection.
    case waitingForConnectivity
}

/// An authentication challenge, for answering with a credential.
public struct HTTPChallenge: Equatable, Sendable {

    public var method: HTTPAuthenticationMethod

    public var host: String

    public var realm: String?

    /// Earlier credentials that were rejected for this challenge.
    public var previousFailureCount: Int32
}

/// Answers an authentication challenge: a credential, or `nil` for the
/// host's default handling (usually failing with
/// `userAuthenticationRequired`).
public typealias HTTPChallengeHandler = (HTTPChallenge) -> (any HTTPCredential)?

/// Async/await over `HTTPSession` tasks (§6.2.1): the guest-side convenience
/// layer. Native hosts never see it.
///
/// ```swift
/// let session = HTTPSessionProxy.shared()
/// guard let request = HTTPRequestProxy.make(url: "https://example.com") else { return }
/// let result = try await session.data(for: request)
/// print(result.statusCode, result.body.count)
/// ```
///
/// Cancelling the task cancels the request: the call throws `cancelled`.
public extension HTTPSession {

    /// Loads a request and returns the response with its whole body.
    ///
    /// - Parameters:
    ///   - followRedirects: Whether to follow redirects; if not, the redirect
    ///     response is the result.
    ///   - challenge: Answers authentication challenges.
    func data(
        for request: any HTTPRequest,
        followRedirects: Bool = true,
        challenge: HTTPChallengeHandler? = nil
    ) async throws(NetworkError) -> HTTPResult {
        try await load(followRedirects: followRedirects, challenge: challenge) { delegate in
            dataTask(request, delegate: delegate)
        }
    }

    /// Uploads `body` with a request and returns the response with its body.
    func upload(
        for request: any HTTPRequest,
        body: [UInt8],
        followRedirects: Bool = true,
        challenge: HTTPChallengeHandler? = nil
    ) async throws(NetworkError) -> HTTPResult {
        try await load(followRedirects: followRedirects, challenge: challenge) { delegate in
            uploadTask(request, body: body, delegate: delegate)
        }
    }

    /// Runs a request and reports its progress, response and body chunks as
    /// they arrive. The stream finishes when the request completes, by
    /// throwing if it fails. Releasing the stream or cancelling its task
    /// cancels the request.
    ///
    /// - Parameter body: Uploads this body if given.
    func events(
        for request: any HTTPRequest,
        body: [UInt8]? = nil,
        followRedirects: Bool = true,
        challenge: HTTPChallengeHandler? = nil
    ) -> EventStream<HTTPEvent, NetworkError> {
        let (stream, continuation) = EventStream<HTTPEvent, NetworkError>.makeStream()
        let delegate = HTTPTaskEvents(followRedirects: followRedirects, challenge: challenge)
        delegate.stream = continuation
        let task = if let body {
            uploadTask(request, body: body, delegate: delegate)
        } else {
            dataTask(request, delegate: delegate)
        }
        continuation.onTermination = { [delegate, task] in
            if !delegate.isComplete {
                task.cancel()
            }
        }
        task.resume()
        return stream
    }

    private func load(
        followRedirects: Bool,
        challenge: HTTPChallengeHandler?,
        _ makeTask: (HTTPTaskEvents) -> any HTTPTask
    ) async throws(NetworkError) -> HTTPResult {
        let delegate = HTTPTaskEvents(followRedirects: followRedirects, challenge: challenge)
        return try await withCallback { (callback: Callback<HTTPResult, NetworkError>) in
            delegate.result = callback
            let task = makeTask(delegate)
            delegate.task = task
            task.resume()
        } onCancel: { [delegate] callback in
            callback.resume(throwing: .cancelled)
            delegate.task?.cancel()
        }
    }
}

/// The delegate behind one async request. The host holds it until the task
/// completes.
final class HTTPTaskEvents: HTTPTaskDelegate {

    let followRedirects: Bool

    let challenge: HTTPChallengeHandler?

    /// For `data` and `upload`: the whole result.
    var result: Callback<HTTPResult, NetworkError>?

    /// For `events`: everything as it happens.
    var stream: EventStream<HTTPEvent, NetworkError>.Continuation?

    var task: (any HTTPTask)?

    private var response: (any HTTPResponse)?

    private var body: [UInt8] = []

    private(set) var isComplete = false

    init(followRedirects: Bool, challenge: HTTPChallengeHandler?) {
        self.followRedirects = followRedirects
        self.challenge = challenge
    }

    func willPerformRedirect(_ task: any HTTPTask, response: any HTTPResponse, newRequest: any HTTPRequest) -> Bool {
        followRedirects
    }

    func didReceiveChallenge(_ task: any HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> (any HTTPCredential)? {
        challenge?(HTTPChallenge(
            method: HTTPAuthenticationMethod(rawValue: method) ?? .other,
            host: host,
            realm: realm,
            previousFailureCount: previousFailureCount
        ))
    }

    func didReceiveResponse(_ task: any HTTPTask, response: any HTTPResponse) -> Bool {
        self.response = response
        stream?.yield(.response(response))
        return true
    }

    func didReceiveData(_ task: any HTTPTask, data: [UInt8]) {
        if result != nil {
            body.append(contentsOf: data)
        }
        stream?.yield(.data(data))
    }

    func didSendBodyData(_ task: any HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        stream?.yield(.sent(bytes: bytesSent, total: totalBytesSent, expected: totalBytesExpectedToSend))
    }

    func taskIsWaitingForConnectivity(_ task: any HTTPTask) {
        stream?.yield(.waitingForConnectivity)
    }

    func didComplete(_ task: any HTTPTask, error: Int32, message: String?) {
        isComplete = true
        self.task = nil
        let error = NetworkError(code: error)
        if let result {
            if let error {
                result.resume(throwing: error)
            } else if let response {
                result.resume(returning: HTTPResult(response: response, body: body))
            } else {
                result.resume(throwing: .badServerResponse)
            }
        }
        stream?.finish(throwing: error)
    }
}
#endif
