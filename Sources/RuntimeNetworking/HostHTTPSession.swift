import DynamicNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPSession` over one `URLSession`.
///
/// The URLSession's delegate is a `SessionDelegate`, which routes each
/// task's callbacks to its `HostHTTPTask` and from there to the guest's
/// delegate. Callbacks arrive on a serial queue of the session's own, not
/// the main `OperationQueue`: a host with a loop of its own may never run
/// that. Each is carried to the main thread, the only thread the guest is
/// entered from, by `HostNetworkingModule.deliver`, and URLSession's
/// questions are answered from there once the guest has.
///
/// A URLSession keeps its delegate until it's invalidated, so the session
/// is invalidated when the contract session ends: by
/// `finishTasksAndInvalidate()`, `invalidateAndCancel()`, or, if the guest
/// calls neither, when it releases the session (running tasks still finish).
public final class HostHTTPSession: HTTPSession {

    let urlSession: URLSession

    /// The settings tasks are made with, read once.
    private let settings: URLSessionConfiguration

    /// The process-wide session, which ignores invalidation as
    /// `URLSession.shared` does.
    private let isShared: Bool

    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

    private(set) var isInvalidated = false

    /// Identifiers for tasks that never reach URLSession, which numbers its
    /// own from 0 up.
    private var nextFailedIdentifier: Int64 = -1

    init(configuration: URLSessionConfiguration, isShared: Bool = false) {
        let deliver = HostNetworkingModule.deliver
        let queue = OperationQueue()
        queue.name = "org.pureswift.runtime.networking"
        queue.maxConcurrentOperationCount = 1
        self.urlSession = URLSession(configuration: configuration, delegate: SessionDelegate(deliver: deliver), delegateQueue: queue)
        self.settings = urlSession.configuration
        self.isShared = isShared
        self.deliver = deliver
    }

    deinit {
        if !isInvalidated {
            urlSession.finishTasksAndInvalidate()
        }
    }

    nonisolated(unsafe) private static var sharedSession: HostHTTPSession?

    public static func shared() -> HostHTTPSession {
        if let sharedSession {
            return sharedSession
        }
        let session = HostHTTPSession(configuration: .default, isShared: true)
        sharedSession = session
        return session
    }

    public static func make(_ configuration: any HTTPSessionConfiguration) -> HostHTTPSession {
        HostHTTPSession(configuration: HostHTTPSessionConfiguration.urlSessionConfiguration(for: configuration))
    }

    public func configuration() -> any HTTPSessionConfiguration {
        HostHTTPSessionConfiguration(urlSession.configuration)
    }

    public func dataTask(_ request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, delegate: delegate) { urlSession.dataTask(with: $0) }
    }

    public func uploadTask(_ request: any HTTPRequest, body: [UInt8], delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, delegate: delegate) { urlSession.uploadTask(with: $0, from: Data(body)) }
    }

    public func finishTasksAndInvalidate() {
        guard invalidate() else { return }
        urlSession.finishTasksAndInvalidate()
    }

    public func invalidateAndCancel() {
        guard invalidate() else { return }
        urlSession.invalidateAndCancel()
    }

    public func removeAllCookies() {
        settings.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    public func removeAllCachedResponses() {
        settings.urlCache?.removeAllCachedResponses()
    }

    // MARK: Tasks

    private func makeTask(
        _ request: any HTTPRequest,
        delegate: any HTTPTaskDelegate,
        _ make: (URLRequest) -> URLSessionTask
    ) -> HostHTTPTask {
        // URLSession raises an exception (Apple platforms) or stops the
        // process (swift-corelibs-foundation) for a task made after
        // invalidation.
        guard !isInvalidated, let owner = urlSession.delegate as? SessionDelegate else {
            return failedTask(.sessionInvalidated, request: request, delegate: delegate)
        }
        guard let urlRequest = HostHTTPRequest.urlRequest(for: request, in: settings) else {
            return failedTask(.invalidURL, request: request, delegate: delegate)
        }
        return HostHTTPTask(task: make(urlRequest), owner: owner, delegate: delegate)
    }

    private func failedTask(_ failure: NetworkError, request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> HostHTTPTask {
        let identifier = nextFailedIdentifier
        nextFailedIdentifier -= 1
        return HostHTTPTask(failing: failure, request: request, identifier: identifier, delegate: delegate, deliver: deliver)
    }

    /// Marks the session invalidated. False for the shared session, or one
    /// already invalidated.
    private func invalidate() -> Bool {
        if isShared {
            HostNetworkingModule.log?("The shared HTTPSession can't be invalidated; ignoring")
            return false
        }
        guard !isInvalidated else { return false }
        isInvalidated = true
        return true
    }
}

/// The URLSession delegate behind one `HostHTTPSession`: forwards each
/// task's events to its `HostHTTPTask`'s guest delegate, on the main
/// thread, and answers URLSession's questions with the guest's replies.
///
/// URLSession calls it on the session's own queue. Each callback carries
/// only URLSession's objects to the main thread (`deliver`), and looks up
/// the task and its guest delegate there, so no guest object is retained or
/// released anywhere else. URLSession's completion handlers are then called
/// from the main thread, once the guest has answered.
///
/// It keeps every task that has been resumed or cancelled until the task
/// completes; `tasks` is the main thread's. URLSession keeps it until the
/// session is invalidated.
final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Running tasks by `taskIdentifier`.
    private var tasks: [Int: HostHTTPTask] = [:]

    init(deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.deliver = deliver
    }

    /// Call on the main thread.
    func track(_ task: HostHTTPTask) {
        guard let urlTask = task.task else { return }
        tasks[urlTask.taskIdentifier] = task
    }

    /// The task and its guest delegate, if it hasn't completed yet.
    private func route(_ task: URLSessionTask) -> (HostHTTPTask, any HTTPTaskDelegate)? {
        guard let owner = tasks[task.taskIdentifier], let delegate = owner.delegate else {
            return nil
        }
        return (owner, delegate)
    }

    /// Runs `body` on the main thread. What it captures comes from
    /// URLSession, not the guest, and may be sent there.
    private func onMain(_ body: @escaping () -> Void) {
        let body = Unchecked(body)
        deliver {
            body.value()
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        onMain { [self] in
            guard let (owner, delegate) = route(task) else {
                completionHandler(request)
                return
            }
            let newRequest = HostHTTPRequest(request)
            let follow = autoreleasing {
                delegate.willPerformRedirect(owner, response: owner.wrap(response), newRequest: newRequest)
            }
            // The guest may have changed the new request, such as its headers.
            completionHandler(follow ? newRequest.request : nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        onMain { [self] in
            let space = challenge.protectionSpace
            // Server trust and client certificates stay with the host.
            guard let method = HTTPAuthenticationMethod(space), let (owner, delegate) = route(task) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let answer = autoreleasing {
                delegate.didReceiveChallenge(
                    owner,
                    method: method.rawValue,
                    host: space.host,
                    realm: space.realm,
                    previousFailureCount: Int32(clamping: challenge.previousFailureCount)
                )
            }
            guard let answer else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let credential = HostNetworkingModule.host(answer, as: HostHTTPCredential.self) else {
                // Its password can't be read: the contract makes it write-only.
                HostNetworkingModule.log?("HTTPTaskDelegate.didReceiveChallenge returned a credential this host didn't make; using the default handling")
                completionHandler(.performDefaultHandling, nil)
                return
            }
            #if canImport(FoundationNetworking)
            // swift-corelibs-foundation answers only HTTP Basic with a
            // credential; for any other method it stops the process.
            guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
                HostNetworkingModule.log?("HTTPTaskDelegate.didReceiveChallenge answered a \(space.authenticationMethod) challenge, which this platform's URLSession can't use a credential for; using the default handling")
                completionHandler(.performDefaultHandling, nil)
                return
            }
            #endif
            completionHandler(.useCredential, credential.credential)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onMain { [self] in
            guard let (owner, delegate) = route(task) else { return }
            autoreleasing {
                delegate.didSendBodyData(
                    owner,
                    bytesSent: bytesSent,
                    totalBytesSent: totalBytesSent,
                    totalBytesExpectedToSend: totalBytesExpectedToSend
                )
            }
        }
    }

    /// Never called off Apple platforms, where tasks don't wait.
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        onMain { [self] in
            guard let (owner, delegate) = route(task) else { return }
            autoreleasing {
                delegate.taskIsWaitingForConnectivity(owner)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onMain { [self] in
            guard let owner = tasks.removeValue(forKey: task.taskIdentifier) else { return }
            guard let error else {
                if owner.refusedResponse {
                    owner.complete(error: NetworkError.cancelled.rawValue, message: "cancelled")
                } else {
                    owner.complete(error: 0, message: nil)
                }
                return
            }
            let code = NetworkError(urlSessionError: error)
            NetworkError.report(error, code: code)
            owner.complete(error: code.rawValue, message: error.localizedDescription)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        onMain { [self] in
            guard let (owner, delegate) = route(dataTask) else {
                completionHandler(.allow)
                return
            }
            let allow = autoreleasing {
                delegate.didReceiveResponse(owner, response: owner.wrap(response))
            }
            guard allow else {
                owner.refusedResponse = true
                completionHandler(.cancel)
                #if canImport(FoundationNetworking)
                // swift-corelibs-foundation disregards the disposition and
                // goes on loading.
                dataTask.cancel()
                #endif
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onMain { [self] in
            guard let (owner, delegate) = route(dataTask), !owner.refusedResponse else { return }
            autoreleasing {
                delegate.didReceiveData(owner, data: [UInt8](data))
            }
        }
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        onMain { [self] in
            // Every task has completed by now; complete any left so no guest
            // delegate waits forever.
            let left = tasks
            tasks = [:]
            for task in left.values {
                task.complete(error: NetworkError.sessionInvalidated.rawValue, message: "The session was invalidated")
            }
            if let error {
                HostNetworkingModule.log?("HTTPSession invalidated with an error: \(error.localizedDescription)")
            }
        }
    }
}

/// A value sent to the main thread that the compiler can't prove may be:
/// URLSession's objects and completion handlers.
private struct Unchecked<Value>: @unchecked Sendable {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension HTTPAuthenticationMethod {

    /// The method the guest is asked about, or nil for challenges the host
    /// answers itself (server trust, client certificates).
    init?(_ space: URLProtectionSpace) {
        switch space.authenticationMethod {
        case Self.serverTrust, Self.clientCertificate:
            return nil
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault:
            self = space.isProxy() ? .proxyBasic : .basic
        case NSURLAuthenticationMethodHTTPDigest:
            self = .digest
        default:
            // NTLM, Negotiate, HTML forms.
            self = .other
        }
    }

    #if canImport(FoundationNetworking)
    // swift-corelibs-foundation marks these unavailable: it never asks
    // about either, though a `URLProtocol` still could.
    static let serverTrust = "NSURLAuthenticationMethodServerTrust"
    static let clientCertificate = "NSURLAuthenticationMethodClientCertificate"
    #else
    static let serverTrust = NSURLAuthenticationMethodServerTrust
    static let clientCertificate = NSURLAuthenticationMethodClientCertificate
    #endif
}
