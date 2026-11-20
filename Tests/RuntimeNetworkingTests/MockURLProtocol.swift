import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers a test session's requests without a network. Each test sets a
/// handler for its URL path before starting a task.
///
/// swift-corelibs-foundation's URLSession stops the process when a
/// `URLProtocol` reports a redirect, and retries a challenge answered with
/// a credential over its own HTTP protocol, so on Linux the tests drive the
/// session's delegate directly for those.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()

    nonisolated(unsafe) private static var handlerTable: [String: @Sendable (MockURLProtocol) -> Void] = [:]

    nonisolated(unsafe) private static var startedPaths: [String] = []

    /// Forgets every handler and request.
    static func reset() {
        lock.withLock {
            handlerTable = [:]
            startedPaths = []
        }
    }

    /// Answers requests for `path`. Set before a task starts.
    static func handle(_ path: String, _ handler: @escaping @Sendable (MockURLProtocol) -> Void) {
        lock.withLock { handlerTable[path] = handler }
    }

    /// Requests that reached the protocol, by path.
    static var started: [String] {
        lock.withLock { startedPaths }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let handler = Self.lock.withLock {
            Self.startedPaths.append(path)
            return Self.handlerTable[path]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        handler(self)
    }

    override func stopLoading() { }

    // MARK: Answers

    /// The request body, whether URLSession passed it as data or a stream.
    var requestBody: [UInt8] {
        if let body = request.httpBody {
            return [UInt8](body)
        }
        guard let stream = request.httpBodyStream else {
            return []
        }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return bytes
    }

    func respond(status: Int, headers: [String: String] = [:], chunks: [[UInt8]]) {
        client?.urlProtocol(self, didReceive: response(status: status, headers: headers), cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: Data(chunk))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Sends one chunk at a time, `interval` seconds apart, so URLSession
    /// delivers them separately.
    func stream(status: Int, chunks: [[UInt8]], interval: TimeInterval) {
        client?.urlProtocol(self, didReceive: response(status: status, headers: [:]), cacheStoragePolicy: .notAllowed)
        #if canImport(FoundationNetworking)
        // Loading runs on a dispatch queue here, without a run loop.
        // swift-corelibs-foundation's `URLProtocol` can't be `Sendable`.
        let loader = UncheckedLoader(self)
        @Sendable func send(_ remaining: [[UInt8]]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                let this = loader.value
                guard let chunk = remaining.first else {
                    this.client?.urlProtocolDidFinishLoading(this)
                    return
                }
                this.client?.urlProtocol(this, didLoad: Data(chunk))
                send(Array(remaining.dropFirst()))
            }
        }
        send(chunks)
        #else
        // From the loading thread's run loop.
        var remaining = chunks
        let timer = Timer(timeInterval: interval, repeats: true) { [self] timer in
            guard !remaining.isEmpty else {
                timer.invalidate()
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: Data(remaining.removeFirst()))
        }
        RunLoop.current.add(timer, forMode: .common)
        #endif
    }

    private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    #if !canImport(FoundationNetworking)
    func redirect(to location: String, status: Int = 302) {
        let url = URL(string: location, relativeTo: request.url)!.absoluteURL
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
        var newRequest = request
        newRequest.url = url
        client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)
        // If the delegate refuses the redirect, the redirect is the response.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    func challenge(method: String, realm: String, previousFailureCount: Int = 0, answer: @escaping @Sendable (URLCredential?) -> Void) {
        client?.urlProtocol(self, didReceive: Self.challenge(host: request.url!.host!, method: method, realm: realm, previousFailureCount: previousFailureCount, answer: answer))
    }
    #endif

    /// A challenge from `host` whose answer goes to `answer`.
    static func challenge(
        host: String,
        method: String,
        realm: String?,
        isProxy: Bool = false,
        previousFailureCount: Int = 0,
        answer: @escaping @Sendable (URLCredential?) -> Void = { _ in }
    ) -> URLAuthenticationChallenge {
        let space = isProxy
            ? URLProtectionSpace(proxyHost: host, port: 8080, type: "https", realm: realm, authenticationMethod: method)
            : URLProtectionSpace(host: host, port: 443, protocol: "https", realm: realm, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender(answer)
        )
    }
}

/// A loader sent to another queue.
struct UncheckedLoader: @unchecked Sendable {

    let value: MockURLProtocol

    init(_ value: MockURLProtocol) {
        self.value = value
    }
}

/// Passes the answer to a challenge from `MockURLProtocol` to its handler.
final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {

    let answer: @Sendable (URLCredential?) -> Void

    init(_ answer: @escaping @Sendable (URLCredential?) -> Void) {
        self.answer = answer
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        answer(credential)
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        answer(nil)
    }
}
