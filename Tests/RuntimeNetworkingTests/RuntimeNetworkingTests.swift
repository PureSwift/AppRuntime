import Dispatch
import DynamicNetworking
import DynamicRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RuntimeNetworking

/// The URLSession-backed contracts against `MockURLProtocol`, on macOS and
/// Linux. The session's callbacks are carried to the main queue by
/// `HostNetworkingModule.deliver`, and the tests wait for them there, on the
/// main actor; every guest callback checks it's on the main queue.
///
/// Serialized: the mock's handlers, `deliver` and `log` are shared.
@MainActor
@Suite(.serialized) struct HostHTTPSessionTests {

    init() {
        #expect(isOnMainQueue)
        MockURLProtocol.reset()
        HostNetworkingModule.deliver = HostNetworkingModule.onMain
        HostNetworkingModule.log = nil
    }

    func makeSession(_ configure: (HostHTTPSessionConfiguration) -> Void = { _ in }) -> HostHTTPSession {
        let configuration = HostHTTPSessionConfiguration.makeEphemeral()
        configuration.urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        configuration.setTimeoutForRequest(5)
        configure(configuration)
        return HostHTTPSession.make(configuration)
    }

    func request(_ path: String) throws -> HostHTTPRequest {
        try #require(HostHTTPRequest.make(url: "https://example.com\(path)"))
    }

    /// Runs a task to completion.
    @discardableResult
    func run(_ task: any HTTPTask, _ delegate: RecordingTaskDelegate) async -> RecordingTaskDelegate {
        task.resume()
        await delegate.completion()
        return delegate
    }

    /// Waits up to five seconds for `condition`, letting the main queue run.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A running task whose request never gets an answer, for driving the
    /// session's URLSession delegate directly. Cancel it when done.
    func heldTask(_ session: HostHTTPSession, _ delegate: RecordingTaskDelegate) async throws -> (HostHTTPTask, URLSessionTask, SessionDelegate) {
        MockURLProtocol.handle("/hold") { _ in }
        let task = try #require(session.dataTask(try request("/hold"), delegate: delegate) as? HostHTTPTask)
        task.resume()
        await waitUntil { MockURLProtocol.started.contains("/hold") }
        return (task, try #require(task.task), try #require(session.urlSession.delegate as? SessionDelegate))
    }

    // MARK: Delivery

    @Test func roundTrip() async throws {
        MockURLProtocol.handle("/echo") { loader in
            let request = loader.request
            loader.respond(
                status: 201,
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "X-Method": request.httpMethod ?? "",
                    "X-Echo": request.value(forHTTPHeaderField: "X-Test") ?? "",
                    "X-Extra": request.value(forHTTPHeaderField: "X-Extra") ?? "",
                ],
                chunks: [loader.requestBody]
            )
        }
        let session = makeSession { $0.setAdditionalHeader("X-Extra", value: "session") }
        let request = try request("/echo")
        request.setMethod("PUT")
        request.setHeader("X-Test", value: "hello")
        request.setBody(Array("payload".utf8))
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(request, delegate: delegate)
        #expect(task.state() == HTTPTaskState.suspended.rawValue)
        await run(task, delegate)

        #expect(delegate.error == 0)
        #expect(delegate.message == nil)
        let response = try #require(delegate.response)
        #expect(response.statusCode() == 201)
        #expect(response.url() == "https://example.com/echo")
        #expect(response.header("x-method") == "PUT", "lookup is case-insensitive")
        #expect(response.header("X-Echo") == "hello")
        #if !canImport(FoundationNetworking)
        // swift-corelibs-foundation adds the session's headers in its own
        // protocols, not before a `URLProtocol` sees the request.
        #expect(response.header("X-Extra") == "session")
        #endif
        #expect(response.headerNames().contains("X-Method"))
        #expect(response.mimeType() == "text/plain")
        #expect(delegate.body == Array("payload".utf8))
        #expect(delegate.events.first == "response")
        #expect(delegate.events.last == "complete 0")

        #expect(task.state() == HTTPTaskState.completed.rawValue)
        #expect(task.originalRequest().method() == "PUT")
        #expect(task.response() === response, "one wrapper per response")
        #if !canImport(FoundationNetworking)
        // swift-corelibs-foundation counts the bytes only its own protocols
        // load, not a `URLProtocol`'s.
        #expect(task.countOfBytesReceived() == Int64("payload".utf8.count))
        #endif
    }

    /// Every callback goes through `deliver`, which a host with a loop of
    /// its own replaces; a session keeps the one it was made with.
    @Test func deliversThroughTheModulesDeliver() async throws {
        MockURLProtocol.handle("/echo") { $0.respond(status: 200, chunks: [[1], [2]]) }
        let counter = DeliveryCounter()
        HostNetworkingModule.deliver = { work in
            counter.increment()
            DispatchQueue.main.async(execute: work)
        }
        let session = makeSession()
        HostNetworkingModule.deliver = HostNetworkingModule.onMain
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(try request("/echo"), delegate: delegate), delegate)
        #expect(delegate.error == 0)
        #expect(delegate.body == [1, 2])
        // A response, at least one chunk and the completion.
        #expect(counter.count >= 3)

        // A task that never reaches URLSession completes through it too.
        let before = counter.count
        let failed = RecordingTaskDelegate()
        await run(session.dataTask(GuestRequest(url: "ftp://example.com"), delegate: failed), failed)
        #expect(failed.error == NetworkError.invalidURL.rawValue)
        #expect(counter.count == before + 1)
        session.invalidateAndCancel()
    }

    @Test func uploadSendsTheBody() async throws {
        MockURLProtocol.handle("/upload") { loader in
            loader.respond(status: 200, chunks: [Array("\(loader.requestBody.count)".utf8)])
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.uploadTask(try request("/upload"), body: [UInt8](repeating: 7, count: 100), delegate: delegate)
        await run(task, delegate)
        #expect(delegate.error == 0)
        #if !canImport(FoundationNetworking)
        // swift-corelibs-foundation doesn't give a `URLProtocol` an upload
        // task's body.
        #expect(delegate.body == Array("100".utf8))
        #endif
    }

    /// URLSession reports progress from its own protocols, not a
    /// `URLProtocol`'s, so this is URLSession's call, made directly.
    @Test func uploadReportsProgress() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let (task, urlTask, events) = try await heldTask(session, delegate)
        events.urlSession(session.urlSession, task: urlTask, didSendBodyData: 40, totalBytesSent: 40, totalBytesExpectedToSend: 100)
        events.urlSession(session.urlSession, task: urlTask, didSendBodyData: 60, totalBytesSent: 100, totalBytesExpectedToSend: 100)
        await waitUntil { delegate.progress.count == 2 }
        #expect(delegate.progress.map(\.bytesSent) == [40, 60])
        #expect(delegate.progress.map(\.totalBytesSent) == [40, 100])
        #expect(delegate.events == ["sent 40/100", "sent 100/100"])
        task.cancel()
        await delegate.completion()
    }

    /// URLSession coalesces small chunks that arrive close together.
    nonisolated static let chunks: [[UInt8]] = [
        [UInt8](repeating: 1, count: 8192), [UInt8](repeating: 2, count: 8192), [3],
    ]

    @Test func streamsChunks() async throws {
        MockURLProtocol.handle("/chunks") { loader in
            loader.stream(status: 200, chunks: Self.chunks, interval: 0.1)
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(try request("/chunks"), delegate: delegate), delegate)
        #expect(delegate.error == 0)
        #expect(delegate.chunks == Self.chunks)
        #expect(delegate.events == ["response", "data", "data", "data", "complete 0"])
    }

    // MARK: Redirects

    /// URLSession's redirect question, asked directly, answered once the
    /// guest has, on the main queue.
    func redirect(_ session: HostHTTPSession, _ urlTask: URLSessionTask, _ events: SessionDelegate) async throws -> URLRequest? {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/hold")!, statusCode: 301, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/new"]
        ))
        let newRequest = URLRequest(url: URL(string: "https://example.com/new")!)
        return await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            events.urlSession(session.urlSession, task: urlTask, willPerformHTTPRedirection: response, newRequest: newRequest) { request in
                #expect(isOnMainQueue)
                continuation.resume(returning: request)
            }
        }
    }

    @Test func redirectAllowed() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let (task, urlTask, events) = try await heldTask(session, delegate)
        let follow = try await redirect(session, urlTask, events)
        #expect(follow?.url?.absoluteString == "https://example.com/new")
        #expect(delegate.redirects.map(\.status) == [301])
        #expect(delegate.redirects.map(\.url) == ["https://example.com/new"])
        task.cancel()
        await delegate.completion()
    }

    @Test func redirectRefused() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.followsRedirects = false
        let (task, urlTask, events) = try await heldTask(session, delegate)
        let follow = try await redirect(session, urlTask, events)
        #expect(follow == nil)
        #expect(delegate.redirects.count == 1)
        task.cancel()
        await delegate.completion()
    }

    #if !canImport(FoundationNetworking)
    @Test func followsAnAllowedRedirect() async throws {
        MockURLProtocol.handle("/old") { $0.redirect(to: "/new") }
        MockURLProtocol.handle("/new") { $0.respond(status: 200, chunks: [[42]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/old"), delegate: delegate)
        await run(task, delegate)
        #expect(delegate.error == 0)
        #expect(delegate.redirects.map(\.status) == [302])
        #expect(delegate.redirects.map(\.url) == ["https://example.com/new"])
        #expect(delegate.response?.statusCode() == 200)
        #expect(delegate.response?.url() == "https://example.com/new")
        #expect(delegate.body == [42])
        #expect(task.currentRequest()?.url() == "https://example.com/new")
        #expect(task.originalRequest().url() == "https://example.com/old")
    }

    @Test func refusedRedirectCompletesWithTheRedirect() async throws {
        MockURLProtocol.handle("/old") { $0.redirect(to: "/new") }
        MockURLProtocol.handle("/new") { $0.respond(status: 200, chunks: [[42]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.followsRedirects = false
        await run(session.dataTask(try request("/old"), delegate: delegate), delegate)
        #expect(delegate.redirects.count == 1)
        #expect(delegate.error == 0)
        #expect(delegate.response?.statusCode() == 302)
        #expect(!MockURLProtocol.started.contains("/new"))
    }
    #endif

    // MARK: Challenges

    /// URLSession's challenge, asked directly, answered once the guest has,
    /// on the main queue.
    func answer(
        _ challenge: URLAuthenticationChallenge,
        _ session: HostHTTPSession,
        _ urlTask: URLSessionTask,
        _ events: SessionDelegate
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(URLSession.AuthChallengeDisposition, URLCredential?), Never>) in
            events.urlSession(session.urlSession, task: urlTask, didReceive: challenge) { disposition, credential in
                #expect(isOnMainQueue)
                continuation.resume(returning: (disposition, credential))
            }
        }
    }

    @Test func basicChallengeAnsweredWithAHostCredential() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.credential = {
            HostHTTPCredential.make(user: "user", password: "secret", persistence: HTTPCredentialPersistence.forSession.rawValue)
        }
        let (task, urlTask, events) = try await heldTask(session, delegate)
        let challenge = MockURLProtocol.challenge(host: "example.com", method: NSURLAuthenticationMethodHTTPBasic, realm: "test", previousFailureCount: 1)
        let (disposition, credential) = await answer(challenge, session, urlTask, events)
        #expect(disposition == .useCredential)
        #expect(credential?.user == "user")
        #expect(credential?.password == "secret")
        #expect(credential?.persistence == .forSession)
        #expect(delegate.challenges.count == 1)
        #expect(delegate.challenges.first?.method == HTTPAuthenticationMethod.basic.rawValue)
        #expect(delegate.challenges.first?.host == "example.com")
        #expect(delegate.challenges.first?.realm == "test")
        #expect(delegate.challenges.first?.previousFailureCount == 1)

        // A proxy's.
        let proxy = MockURLProtocol.challenge(host: "proxy.example.com", method: NSURLAuthenticationMethodHTTPBasic, realm: nil, isProxy: true)
        #expect(await answer(proxy, session, urlTask, events).0 == .useCredential)
        #expect(delegate.challenges.last?.method == HTTPAuthenticationMethod.proxyBasic.rawValue)
        #expect(delegate.challenges.last?.realm == nil)
        task.cancel()
        await delegate.completion()
    }

    @Test func challengesTheGuestCantAnswer() async throws {
        var messages: [String] = []
        HostNetworkingModule.log = { messages.append($0) }
        defer { HostNetworkingModule.log = nil }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let (task, urlTask, events) = try await heldTask(session, delegate)

        // No credential: the default handling.
        let digest = MockURLProtocol.challenge(host: "example.com", method: NSURLAuthenticationMethodHTTPDigest, realm: "test")
        var (disposition, credential) = await answer(digest, session, urlTask, events)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
        #expect(delegate.challenges.last?.method == HTTPAuthenticationMethod.digest.rawValue)

        // Server trust never reaches the guest.
        let trust = MockURLProtocol.challenge(host: "example.com", method: HTTPAuthenticationMethod.serverTrust, realm: nil)
        (disposition, credential) = await answer(trust, session, urlTask, events)
        #expect(disposition == .performDefaultHandling)
        #expect(delegate.challenges.count == 1)

        // A credential whose password the host can't read.
        delegate.credential = { GuestCredential() }
        let basic = MockURLProtocol.challenge(host: "example.com", method: NSURLAuthenticationMethodHTTPBasic, realm: "test")
        (disposition, credential) = await answer(basic, session, urlTask, events)
        #expect(disposition == .performDefaultHandling)
        #expect(messages.last?.contains("didn't make") == true)

        // A host credential for digest: only Apple platforms' URLSession
        // can use one.
        delegate.credential = { HostHTTPCredential.make(user: "u", password: "p", persistence: 0) }
        (disposition, credential) = await answer(digest, session, urlTask, events)
        #if canImport(FoundationNetworking)
        #expect(disposition == .performDefaultHandling)
        #expect(messages.last?.contains(NSURLAuthenticationMethodHTTPDigest) == true)
        #else
        #expect(disposition == .useCredential)
        #endif
        task.cancel()
        await delegate.completion()
    }

    #if !canImport(FoundationNetworking)
    @Test func answersAChallengeWithACredential() async throws {
        MockURLProtocol.handle("/private") { loader in
            loader.challenge(method: NSURLAuthenticationMethodHTTPBasic, realm: "test") { credential in
                if let credential, credential.user == "user", credential.password == "secret" {
                    loader.respond(status: 200, chunks: [Array("welcome".utf8)])
                } else {
                    loader.respond(status: 401, chunks: [])
                }
            }
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.credential = {
            HostHTTPCredential.make(user: "user", password: "secret", persistence: HTTPCredentialPersistence.none.rawValue)
        }
        await run(session.dataTask(try request("/private"), delegate: delegate), delegate)
        #expect(delegate.challenges.count == 1)
        #expect(delegate.response?.statusCode() == 200)
        #expect(delegate.body == Array("welcome".utf8))
    }
    #endif

    // MARK: Failures

    @Test func mapsFailures() async throws {
        MockURLProtocol.handle("/slow") { $0.fail(URLError(.timedOut)) }
        MockURLProtocol.handle("/lost") { $0.fail(URLError(.networkConnectionLost)) }
        MockURLProtocol.handle("/odd") { $0.fail(NSError(domain: "Odd", code: 7)) }
        var messages: [String] = []
        HostNetworkingModule.log = { messages.append($0) }
        defer { HostNetworkingModule.log = nil }
        let session = makeSession()
        let expected: [(String, NetworkError)] = [
            ("/slow", .timedOut), ("/lost", .connectionLost), ("/odd", .unknown),
        ]
        for (path, error) in expected {
            let delegate = RecordingTaskDelegate()
            await run(session.dataTask(try request(path), delegate: delegate), delegate)
            #expect(delegate.error == error.rawValue, "\(path)")
            #expect(delegate.message != nil)
            #expect(delegate.response == nil)
        }
        // Only the failure without a code is logged.
        #expect(messages.count == 1)
        #expect(messages.first?.contains("Odd 7") == true)
    }

    @Test func errorTable() {
        func code(_ error: Error) -> NetworkError {
            NetworkError(urlSessionError: error)
        }
        #expect(code(URLError(.cancelled)) == .cancelled)
        #expect(code(URLError(.badURL)) == .invalidURL)
        #expect(code(URLError(.unsupportedURL)) == .invalidURL)
        #expect(code(URLError(.timedOut)) == .timedOut)
        #expect(code(URLError(.cannotFindHost)) == .cannotFindHost)
        #expect(code(URLError(.dnsLookupFailed)) == .cannotFindHost)
        #expect(code(URLError(.cannotConnectToHost)) == .cannotConnectToHost)
        #expect(code(URLError(.networkConnectionLost)) == .connectionLost)
        #expect(code(URLError(.notConnectedToInternet)) == .notConnectedToInternet)
        #expect(code(URLError(.internationalRoamingOff)) == .networkAccessNotAllowed)
        #expect(code(URLError(.dataNotAllowed)) == .networkAccessNotAllowed)
        #expect(code(URLError(.callIsActive)) == .notConnectedToInternet)
        #expect(code(URLError(.secureConnectionFailed)) == .secureConnectionFailed)
        #expect(code(URLError(.clientCertificateRequired)) == .secureConnectionFailed)
        #expect(code(URLError(.serverCertificateHasUnknownRoot)) == .serverCertificateUntrusted)
        #expect(code(URLError(.serverCertificateUntrusted)) == .serverCertificateUntrusted)
        #expect(code(URLError(.appTransportSecurityRequiresSecureConnection)) == .insecureConnectionNotAllowed)
        #expect(code(URLError(.httpTooManyRedirects)) == .tooManyRedirects)
        #expect(code(URLError(.badServerResponse)) == .badServerResponse)
        #expect(code(URLError(.cannotParseResponse)) == .badServerResponse)
        #expect(code(URLError(.userAuthenticationRequired)) == .userAuthenticationRequired)
        #expect(code(URLError(.userCancelledAuthentication)) == .userAuthenticationRequired)
        #expect(code(URLError(.resourceUnavailable)) == .resourceUnavailable)
        #expect(code(URLError(.cannotLoadFromNetwork)) == .resourceUnavailable)
        #expect(code(URLError(.backgroundSessionWasDisconnected)) == .unknown)
        #expect(code(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .timedOut)
        #expect(code(NSError(domain: NSURLErrorDomain, code: -1200)) == .secureConnectionFailed)
        #expect(code(NSError(domain: NSURLErrorDomain, code: -1201)) == .serverCertificateUntrusted, "Apple's bad date")
        #expect(code(CocoaError(.fileNoSuchFile)) == .unknown)
        #expect(code(NetworkError.timedOut) == .unknown)
    }

    @Test func refusingTheResponseCancels() async throws {
        MockURLProtocol.handle("/big") { $0.respond(status: 200, chunks: [[1], [2]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.allowsResponse = false
        await run(session.dataTask(try request("/big"), delegate: delegate), delegate)
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(delegate.chunks.isEmpty)
        #expect(delegate.events == ["response", "complete 2"])
    }

    // MARK: Cancelling

    @Test func cancellation() async throws {
        MockURLProtocol.handle("/hold") { _ in }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/hold"), delegate: delegate)
        task.resume()
        await waitUntil { MockURLProtocol.started.contains("/hold") }
        #expect(task.state() == HTTPTaskState.running.rawValue)
        task.cancel()
        await delegate.completion()
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(delegate.events == ["complete 2"])
        #expect(task.state() == HTTPTaskState.completed.rawValue)
    }

    @Test func cancellingBeforeResume() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/never"), delegate: delegate)
        task.cancel()
        await delegate.completion()
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(MockURLProtocol.started.isEmpty)
        #expect(task.state() == HTTPTaskState.completed.rawValue)
    }

    @Test func cancellingATaskThatCouldntStart() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(GuestRequest(url: "ftp://example.com"), delegate: delegate)
        task.cancel()
        #expect(task.state() == HTTPTaskState.canceling.rawValue)
        await delegate.completion()
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(task.state() == HTTPTaskState.completed.rawValue)
        task.resume()
        task.cancel()
        #expect(delegate.events == ["complete 2"])
    }

    // MARK: Invalidation

    @Test func invalidateAndCancelReleasesTheDelegates() async throws {
        MockURLProtocol.handle("/hold") { _ in }
        let session = makeSession()
        weak let sessionDelegate = session.urlSession.delegate as? SessionDelegate
        weak var taskDelegate: RecordingTaskDelegate?
        do {
            let delegate = RecordingTaskDelegate()
            taskDelegate = delegate
            session.dataTask(try request("/hold"), delegate: delegate).resume()
            await waitUntil { MockURLProtocol.started.contains("/hold") }
            session.invalidateAndCancel()
            await delegate.completion()
            #expect(delegate.error == NetworkError.cancelled.rawValue)
        }
        await waitUntil { taskDelegate == nil && sessionDelegate == nil }
        #expect(taskDelegate == nil, "the task let its delegate go")
        #expect(sessionDelegate == nil, "URLSession let its delegate go")

        // New tasks fail.
        let late = RecordingTaskDelegate()
        let task = session.dataTask(try request("/hold"), delegate: late)
        #expect(task.identifier() < 0)
        await run(task, late)
        #expect(late.error == NetworkError.sessionInvalidated.rawValue)
        #expect(task.originalRequest().url() == "https://example.com/hold")

        // Again does nothing.
        session.invalidateAndCancel()
        session.finishTasksAndInvalidate()
    }

    /// A task URLSession never completed is completed when the session
    /// becomes invalid, on the main queue.
    @Test func invalidationCompletesWhatsLeft() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let (task, _, events) = try await heldTask(session, delegate)
        events.urlSession(session.urlSession, didBecomeInvalidWithError: nil)
        await delegate.completion()
        #expect(delegate.error == NetworkError.sessionInvalidated.rawValue)
        #expect(delegate.message == "The session was invalidated")
        #expect(task.state() == HTTPTaskState.completed.rawValue)
        task.cancel()
        session.invalidateAndCancel()
    }

    @Test func finishTasksAndInvalidateLetsRunningTasksFinish() async throws {
        MockURLProtocol.handle("/slow") { $0.respond(status: 200, chunks: [[1]]) }
        let session = makeSession()
        weak let sessionDelegate = session.urlSession.delegate as? SessionDelegate
        let delegate = RecordingTaskDelegate()
        session.dataTask(try request("/slow"), delegate: delegate).resume()
        session.finishTasksAndInvalidate()
        await delegate.completion()
        #expect(delegate.error == 0)
        #expect(delegate.body == [1])
        await waitUntil { sessionDelegate == nil }
        #expect(sessionDelegate == nil)
    }

    @Test func releasingTheSessionInvalidatesIt() async throws {
        weak var sessionDelegate: SessionDelegate?
        do {
            let session = makeSession()
            sessionDelegate = session.urlSession.delegate as? SessionDelegate
            #expect(sessionDelegate != nil)
        }
        await waitUntil { sessionDelegate == nil }
        #expect(sessionDelegate == nil)
    }

    @Test func invalidURLFailsOnResume() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let request = GuestRequest(url: "ftp://example.com/file")
        let task = session.dataTask(request, delegate: delegate)
        #expect(task.identifier() < 0)
        #expect(task.state() == HTTPTaskState.suspended.rawValue)
        #expect(task.response() == nil)
        await run(task, delegate)
        #expect(delegate.error == NetworkError.invalidURL.rawValue)
        #expect(delegate.message?.contains("invalidURL") == true)
        #expect(task.originalRequest() === request)
        #expect(task.currentRequest() === request)
        #expect(MockURLProtocol.started.isEmpty)
    }

    @Test func guestImplementedRequest() async throws {
        MockURLProtocol.handle("/echo") { loader in
            loader.respond(status: 200, headers: ["X-Method": loader.request.httpMethod ?? ""], chunks: [loader.requestBody])
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(GuestRequest(url: "https://example.com/echo"), delegate: delegate), delegate)
        #expect(delegate.response?.header("X-Method") == "POST")
        #expect(delegate.body == [1, 2, 3])
    }

    @Test func sharedSessionIgnoresInvalidation() {
        var messages: [String] = []
        HostNetworkingModule.log = { messages.append($0) }
        defer { HostNetworkingModule.log = nil }
        let shared = HostHTTPSession.shared()
        #expect(HostHTTPSession.shared() === shared)
        shared.invalidateAndCancel()
        shared.finishTasksAndInvalidate()
        #expect(!shared.isInvalidated)
        #expect(messages == [
            "The shared HTTPSession can't be invalidated; ignoring",
            "The shared HTTPSession can't be invalidated; ignoring",
        ])
    }
}

/// The value contracts, without a session.
@Suite struct HostNetworkingValueTests {

    @Test func requestDefaults() throws {
        #expect(HostHTTPRequest.make(url: "ftp://example.com") == nil)
        #expect(HostHTTPRequest.make(url: "/relative") == nil)
        #expect(HostHTTPRequest.make(url: "http://") == nil)
        let request = try #require(HostHTTPRequest.make(url: "HTTPS://example.com/a"))
        #expect(request.method() == "GET")
        #expect(request.body() == nil)
        #expect(request.timeout() == 0)
        #expect(request.cachePolicy() == HTTPCachePolicy.useProtocolCachePolicy.rawValue)
        #expect(request.headerNames().isEmpty)
    }

    @Test func requestHeadersAndSessionDefaults() throws {
        let request = try #require(HostHTTPRequest.make(url: "https://example.com"))
        request.setHeader("Accept", value: "a")
        request.setHeader("accept", value: "b")
        #expect(request.header("ACCEPT") == "b", "replaces, case-insensitively")
        request.setHeader("Accept", value: nil)
        #expect(request.header("Accept") == nil)
        request.setBody([1, 2])
        #expect(request.body() == [1, 2])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .returnCacheDataDontLoad
        var urlRequest = request.urlRequest(in: configuration)
        #expect(urlRequest.timeoutInterval == 12)
        #expect(urlRequest.cachePolicy == .returnCacheDataDontLoad)

        request.setTimeout(3)
        request.setCachePolicy(HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue)
        urlRequest = request.urlRequest(in: configuration)
        #expect(urlRequest.timeoutInterval == 3)
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.cachePolicy() == HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue)
    }

    @Test func configuration() {
        let configuration = HostHTTPSessionConfiguration.makeDefault()
        #expect(configuration.timeoutForRequest() == 60)
        configuration.setTimeoutForRequest(5)
        configuration.setTimeoutForResource(50)
        configuration.setAllowsCellularAccess(false)
        configuration.setAllowsExpensiveNetworkAccess(false)
        configuration.setAllowsConstrainedNetworkAccess(false)
        configuration.setWaitsForConnectivity(true)
        configuration.setShouldSetCookies(false)
        configuration.setCachePolicy(HTTPCachePolicy.returnCacheDataElseLoad.rawValue)
        configuration.setMaximumConnectionsPerHost(2)
        configuration.setAdditionalHeader("X-A", value: "1")
        configuration.setAdditionalHeader("x-a", value: "2")
        configuration.setAdditionalHeader("X-B", value: "3")
        configuration.setAdditionalHeader("X-B", value: nil)

        let settings = configuration.urlSessionConfiguration
        #expect(configuration.timeoutForRequest() == 5)
        #expect(configuration.timeoutForResource() == 50)
        #expect(!settings.allowsCellularAccess)
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no expensive or constrained
        // networks, and its `waitsForConnectivity` stops the process when
        // read: the three setters did nothing, and didn't stop it either.
        #else
        #expect(!settings.allowsExpensiveNetworkAccess)
        #expect(!settings.allowsConstrainedNetworkAccess)
        #expect(settings.waitsForConnectivity)
        #endif
        #expect(!settings.httpShouldSetCookies)
        #expect(settings.requestCachePolicy == .returnCacheDataElseLoad)
        #expect(settings.httpMaximumConnectionsPerHost == 2)
        #expect(settings.httpAdditionalHeaders?.count == 1)
        #expect(settings.httpAdditionalHeaders?["x-a"] as? String == "2")

        configuration.setAdditionalHeader("x-a", value: nil)
        #expect(settings.httpAdditionalHeaders == nil)
        configuration.setCachePolicy(99)
        #expect(settings.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test @MainActor func sessionCopiesItsConfiguration() {
        let configuration = HostHTTPSessionConfiguration.makeEphemeral()
        configuration.setTimeoutForRequest(7)
        let session = HostHTTPSession.make(configuration)
        configuration.setTimeoutForRequest(9)
        #expect(session.configuration().timeoutForRequest() == 7)
        session.invalidateAndCancel()
    }

    @Test func credential() {
        let credential = HostHTTPCredential.make(user: "u", password: "p", persistence: HTTPCredentialPersistence.forSession.rawValue)
        #expect(credential.user() == "u")
        #expect(credential.persistence() == HTTPCredentialPersistence.forSession.rawValue)
        #expect(credential.credential.password == "p")
        #expect(credential.credential.persistence == .forSession)
        #expect(HostHTTPCredential.make(user: "u", password: "p", persistence: 99).persistence() == 0)
    }

    @Test func url() throws {
        let url = try #require(HostURL.parse("HTTPS://me@example.com:8443/a/b%20c?x=1&y=a+b&x=%C3%A9&flag#top"))
        #expect(url.scheme() == "https")
        #expect(url.user() == "me")
        #expect(url.host() == "example.com")
        #expect(url.port() == 8443)
        #expect(url.path() == "/a/b%20c")
        #expect(url.query() == "x=1&y=a+b&x=%C3%A9&flag")
        #expect(url.fragment() == "top")

        #expect(HostURL.parse("relative/path") == nil)
        #expect(HostURL.parse("https://example.com")?.path() == "/")
        #expect(HostURL.parse("https://example.com")?.port() == -1)
        #expect(HostURL.parse("https://example.com")?.query() == nil)
        #expect(HostURL.parse("mailto:me@example.com")?.path() == "me@example.com")

        let base = try #require(HostURL.parse("https://example.com/a/b/c"))
        #expect(base.resolve("../d?q")?.absoluteString() == "https://example.com/a/d?q")
        #expect(base.resolve("//other.org/x")?.absoluteString() == "https://other.org/x")
        #expect(base.resolve("#f")?.absoluteString() == "https://example.com/a/b/c#f")
    }

    @Test func queryDecoding() throws {
        let url = try #require(HostURL.parse("https://example.com/?x=1&y=a+b&x=%C3%A9&flag&&z=a%2Bb%3Dc&e="))
        #expect(url.queryValues("x") == ["1", "é"])
        #expect(url.queryValues("y") == ["a b"])
        #expect(url.queryValues("flag") == [""])
        #expect(url.queryValues("z") == ["a+b=c"])
        #expect(url.queryValues("e") == [""])
        #expect(url.queryValues("missing").isEmpty)
        #expect(HostURL.parse("https://example.com/")?.queryValues("x").isEmpty == true)
        #expect(try #require(HostURL.parse("https://example.com/?a%20b=1")).queryValues("a b") == ["1"])

        #expect(HostURL.encodeQueryValue("a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9")
        #expect(HostURL.encodeQueryValue("AZaz09-._~") == "AZaz09-._~")
    }
}

/// `HostNetworkingModule` as a `HostModule`.
@Suite struct HostNetworkingModuleTests {

    static let names = [
        "org.pureswift.network.HTTPSession",
        "org.pureswift.network.HTTPSessionConfiguration",
        "org.pureswift.network.HTTPRequest",
        "org.pureswift.network.HTTPResponse",
        "org.pureswift.network.HTTPTask",
        "org.pureswift.network.HTTPTaskDelegate",
        "org.pureswift.network.HTTPCredential",
        "org.pureswift.network.URL",
    ]

    @Test func listsEveryContract() {
        #expect(Set(HostNetworkingModule.contracts.map(\.name)) == Set(Self.names))
        #expect(HostNetworkingModule.contracts.count == Self.names.count)
        #expect(HostNetworkingModule.contracts.first { $0.name == "org.pureswift.network.HTTPTaskDelegate" }?.kind == .callback)
        #expect(HostNetworkingModule.isUsed(by: ["org.pureswift.network.HTTPSession"]))
        #expect(HostNetworkingModule.permissionProviders().isEmpty)
    }

    @Test func registersImplementationsAndTheCallback() {
        let registrar = RecordingRegistrar()
        HostNetworkingModule.register(in: registrar)
        #expect(Set(registrar.registered.map(\.name)) == Set(Self.names))
        #expect(registrar.registered.count == Self.names.count)
        for (name, implemented) in registrar.registered {
            #expect(implemented == (name != "org.pureswift.network.HTTPTaskDelegate"), "\(name)")
        }
    }
}
