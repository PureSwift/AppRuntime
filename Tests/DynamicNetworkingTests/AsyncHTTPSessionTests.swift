import Testing
@testable import DynamicNetworking
import DynamicRuntime
import RuntimeNative

// MARK: - Host fakes

/// What the fake host does when a task resumes.
enum HostScript {
    nonisolated(unsafe) static var status: Int32 = 200
    nonisolated(unsafe) static var chunks: [[UInt8]] = [[1, 2], [3]]
    nonisolated(unsafe) static var error: Int32 = 0
    /// Ask for a credential before responding.
    nonisolated(unsafe) static var challenge = false
    /// Don't complete; wait for `cancel`.
    nonisolated(unsafe) static var hold = false
    nonisolated(unsafe) static var credentialUser: String?
    nonisolated(unsafe) static var heldTasks: [HostHTTPTask] = []
    nonisolated(unsafe) static var cancelled = 0

    static func reset() {
        status = 200
        chunks = [[1, 2], [3]]
        error = 0
        challenge = false
        hold = false
        credentialUser = nil
        heldTasks = []
        cancelled = 0
    }
}

final class HostHTTPSession: HTTPSession {
    static func shared() -> HostHTTPSession { HostHTTPSession() }
    static func make(_ configuration: any HTTPSessionConfiguration) -> HostHTTPSession { HostHTTPSession() }
    func configuration() -> any HTTPSessionConfiguration { fatalError("unused") }
    func dataTask(_ request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> any HTTPTask {
        HostHTTPTask(request: request, body: nil, delegate: delegate)
    }
    func uploadTask(_ request: any HTTPRequest, body: [UInt8], delegate: any HTTPTaskDelegate) -> any HTTPTask {
        HostHTTPTask(request: request, body: body, delegate: delegate)
    }
    func finishTasksAndInvalidate() { }
    func invalidateAndCancel() { }
    func removeAllCookies() { }
    func removeAllCachedResponses() { }
}

final class HostHTTPRequest: HTTPRequest {
    let urlValue: String
    init(url: String) { self.urlValue = url }
    static func make(url: String) -> HostHTTPRequest? { url.isEmpty ? nil : HostHTTPRequest(url: url) }
    func url() -> String { urlValue }
    func setMethod(_ method: String) { }
    func method() -> String { "GET" }
    func setHeader(_ name: String, value: String?) { }
    func header(_ name: String) -> String? { nil }
    func headerNames() -> [String] { [] }
    func setBody(_ body: [UInt8]?) { }
    func body() -> [UInt8]? { nil }
    func setTimeout(_ seconds: Double) { }
    func timeout() -> Double { 60 }
    func setCachePolicy(_ policy: Int32) { }
    func cachePolicy() -> Int32 { 0 }
}

final class HostHTTPResponse: HTTPResponse {
    func statusCode() -> Int32 { HostScript.status }
    func url() -> String { "https://example.com" }
    func header(_ name: String) -> String? { nil }
    func headerNames() -> [String] { [] }
    func expectedContentLength() -> Int64 { -1 }
    func mimeType() -> String? { nil }
}

final class HostHTTPCredential: HTTPCredential {
    let userValue: String
    init(user: String) { self.userValue = user }
    static func make(user: String, password: String, persistence: Int32) -> HostHTTPCredential { HostHTTPCredential(user: user) }
    func user() -> String { userValue }
    func persistence() -> Int32 { 0 }
}

final class HostHTTPTask: HTTPTask {
    let request: any HTTPRequest
    let body: [UInt8]?
    let delegate: any HTTPTaskDelegate
    init(request: any HTTPRequest, body: [UInt8]?, delegate: any HTTPTaskDelegate) {
        self.request = request
        self.body = body
        self.delegate = delegate
    }
    func identifier() -> Int64 { 1 }
    func resume() {
        if HostScript.hold {
            HostScript.heldTasks.append(self)
            return
        }
        if let body {
            delegate.didSendBodyData(self, bytesSent: Int64(body.count), totalBytesSent: Int64(body.count), totalBytesExpectedToSend: Int64(body.count))
        }
        if HostScript.challenge {
            let credential = delegate.didReceiveChallenge(self, method: HTTPAuthenticationMethod.basic.rawValue, host: "example.com", realm: "test", previousFailureCount: 0)
            HostScript.credentialUser = credential?.user()
        }
        if HostScript.error != 0 {
            delegate.didComplete(self, error: HostScript.error, message: "failed")
            return
        }
        _ = delegate.didReceiveResponse(self, response: HostHTTPResponse())
        for chunk in HostScript.chunks {
            delegate.didReceiveData(self, data: chunk)
        }
        delegate.didComplete(self, error: 0, message: nil)
    }
    func cancel() {
        HostScript.cancelled += 1
        HostScript.heldTasks.removeAll()
        delegate.didComplete(self, error: NetworkError.cancelled.rawValue, message: nil)
    }
    func state() -> Int32 { 0 }
    func originalRequest() -> any HTTPRequest { request }
    func currentRequest() -> (any HTTPRequest)? { request }
    func response() -> (any HTTPResponse)? { nil }
    func countOfBytesSent() -> Int64 { 0 }
    func countOfBytesReceived() -> Int64 { 0 }
    func countOfBytesExpectedToSend() -> Int64 { 0 }
    func countOfBytesExpectedToReceive() -> Int64 { 0 }
    func setPriority(_ priority: Float) { }
    func priority() -> Float { 0.5 }
}

// MARK: - Tests

/// The `HTTPSession` async extensions against a fake host, through the
/// native runtime. Serialized: every test shares `NativeRuntime.shared`.
@Suite(.serialized) struct AsyncHTTPSessionTests {

    var native: NativeRuntime { NativeRuntime.shared }

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HTTPSessionProxy.register(HostHTTPSession.self, in: native)
        HTTPRequestProxy.register(HostHTTPRequest.self, in: native)
        HTTPResponseProxy.register(HostHTTPResponse.self, in: native)
        HTTPCredentialProxy.register(HostHTTPCredential.self, in: native)
        HTTPTaskProxy.register(HostHTTPTask.self, in: native)
        HTTPTaskDelegateProxy.registerInterface(in: native)
        HostScript.reset()
    }

    func request() throws -> any HTTPRequest {
        try #require(HTTPRequestProxy.make(url: "https://example.com"))
    }

    @Test func dataCollectsTheBody() async throws {
        let handles = native.runtime.handleCount
        do {
            let result = try await HTTPSessionProxy.shared().data(for: request())
            #expect(result.statusCode == 200)
            #expect(result.body == [1, 2, 3])
        }
        #expect(native.runtime.handleCount == handles)
        #expect(Exported.liveCount == 0, "the task delegate was released")
    }

    @Test func uploadAndFailure() async throws {
        let session = HTTPSessionProxy.shared()
        HostScript.status = 201
        let result = try await session.upload(for: request(), body: [9, 9])
        #expect(result.statusCode == 201)

        HostScript.error = NetworkError.timedOut.rawValue
        await #expect(throws: NetworkError.timedOut) {
            _ = try await session.data(for: self.request())
        }
    }

    @Test func challengeHandlerAnswers() async throws {
        HostScript.challenge = true
        _ = try await HTTPSessionProxy.shared().data(for: request()) { challenge in
            #expect(challenge.method == .basic)
            #expect(challenge.host == "example.com")
            return HTTPCredentialProxy.make(user: "user", password: "secret", persistence: 0)
        }
        #expect(HostScript.credentialUser == "user")
    }

    @Test func eventsReportProgressResponseAndChunks() async throws {
        var log: [String] = []
        let request = try request()
        for try await event in HTTPSessionProxy.shared().events(for: request, body: [7]) {
            switch event {
            case .sent(let bytes, _, _):
                log.append("sent \(bytes)")
            case .response(let response):
                log.append("response \(response.statusCode())")
            case .data(let chunk):
                log.append("data \(chunk.count)")
            case .waitingForConnectivity:
                log.append("waiting")
            }
        }
        #expect(log == ["sent 1", "response 200", "data 2", "data 1"])
    }

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        HostScript.hold = true
        let session = HTTPSessionProxy.shared()
        let request = try request()
        let load = Task { _ = try await session.data(for: request) }
        while HostScript.heldTasks.isEmpty {
            await Task.yield()
        }
        load.cancel()
        await #expect(throws: NetworkError.cancelled) {
            try await load.value
        }
        #expect(HostScript.cancelled == 1)
    }
}
