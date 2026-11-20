import Dispatch
import DynamicNetworking
import DynamicRuntime
import Foundation
import Testing

/// Marks the main queue, where `HostNetworkingModule.deliver` runs work by
/// default.
nonisolated(unsafe) let mainQueueKey: DispatchSpecificKey<Bool> = {
    let key = DispatchSpecificKey<Bool>()
    DispatchQueue.main.setSpecific(key: key, value: true)
    return key
}()

/// Whether this is running on the main queue: the guest's thread in these
/// tests. Not `Thread.isMainThread`: under `swift test` on Linux, the
/// main queue isn't run on the process's main thread.
var isOnMainQueue: Bool {
    DispatchQueue.getSpecific(key: mainQueueKey) == true
}

/// Records one task's events, as a guest delegate would see them, and
/// checks each arrives on the main queue.
final class RecordingTaskDelegate: HTTPTaskDelegate {

    var events: [String] = []

    var chunks: [[UInt8]] = []

    var body: [UInt8] {
        chunks.flatMap { $0 }
    }

    var response: (any HTTPResponse)?

    var error: Int32?

    var message: String?

    var challenges: [(method: Int32, host: String, realm: String?, previousFailureCount: Int32)] = []

    var redirects: [(status: Int32, url: String)] = []

    var progress: [(bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64)] = []

    /// The answer to `willPerformRedirect`.
    var followsRedirects = true

    /// The answer to `didReceiveChallenge`.
    var credential: (() -> (any HTTPCredential)?)?

    /// The answer to `didReceiveResponse`.
    var allowsResponse = true

    private var continuation: CheckedContinuation<Void, Never>?

    var isComplete: Bool {
        error != nil
    }

    /// Returns once `didComplete` has been called, or records an issue and
    /// returns after `timeout` seconds.
    ///
    /// On the main actor, where the session delivers and so `didComplete`
    /// runs: off it, `didComplete` could run between the `isComplete` check
    /// and storing the continuation, which would then never be resumed.
    @MainActor
    func completion(timeout: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation) async {
        if isComplete { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // Weak: a test checks the delegate is released once the task is.
            let held = WeakHeld(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard let self = held.value, let continuation = self.continuation else { return }
                    self.continuation = nil
                    Issue.record("The task didn't complete within \(timeout) seconds", sourceLocation: sourceLocation)
                    continuation.resume()
                }
            }
        }
    }

    func willPerformRedirect(_ task: any HTTPTask, response: any HTTPResponse, newRequest: any HTTPRequest) -> Bool {
        #expect(isOnMainQueue)
        events.append("redirect")
        redirects.append((response.statusCode(), newRequest.url()))
        return followsRedirects
    }

    func didReceiveChallenge(_ task: any HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> (any HTTPCredential)? {
        #expect(isOnMainQueue)
        events.append("challenge")
        challenges.append((method, host, realm, previousFailureCount))
        return credential?()
    }

    func didReceiveResponse(_ task: any HTTPTask, response: any HTTPResponse) -> Bool {
        #expect(isOnMainQueue)
        events.append("response")
        self.response = response
        return allowsResponse
    }

    func didReceiveData(_ task: any HTTPTask, data: [UInt8]) {
        #expect(isOnMainQueue)
        events.append("data")
        chunks.append(data)
    }

    func didSendBodyData(_ task: any HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        #expect(isOnMainQueue)
        events.append("sent \(totalBytesSent)/\(totalBytesExpectedToSend)")
        progress.append((bytesSent, totalBytesSent, totalBytesExpectedToSend))
    }

    func taskIsWaitingForConnectivity(_ task: any HTTPTask) {
        #expect(isOnMainQueue)
        events.append("waiting")
    }

    func didComplete(_ task: any HTTPTask, error: Int32, message: String?) {
        #expect(isOnMainQueue)
        events.append("complete \(error)")
        self.error = error
        self.message = message
        continuation?.resume()
        continuation = nil
    }
}

/// A weak reference a timer on the main queue can carry.
final class WeakHeld<Value: AnyObject>: @unchecked Sendable {

    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Counts the closures a `deliver` was given, from any thread.
final class DeliveryCounter: @unchecked Sendable {

    private let lock = NSLock()

    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [(name: String, implemented: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        let implemented: Bool
        if case .some = statics {
            implemented = true
        } else {
            implemented = false
        }
        registered.append((descriptor.name, implemented))
    }
}

/// A request the guest implemented itself, read through the protocol.
final class GuestRequest: HTTPRequest {
    let urlValue: String
    init(url: String) { urlValue = url }
    static func make(url: String) -> GuestRequest? { GuestRequest(url: url) }
    func url() -> String { urlValue }
    func setMethod(_ method: String) { }
    func method() -> String { "POST" }
    func setHeader(_ name: String, value: String?) { }
    func header(_ name: String) -> String? { name == "Content-Type" ? "application/octet-stream" : nil }
    func headerNames() -> [String] { ["Content-Type"] }
    func setBody(_ body: [UInt8]?) { }
    func body() -> [UInt8]? { [1, 2, 3] }
    func setTimeout(_ seconds: Double) { }
    func timeout() -> Double { 0 }
    func setCachePolicy(_ policy: Int32) { }
    func cachePolicy() -> Int32 { 0 }
}

/// A credential the guest implemented itself, whose password the host
/// can't read.
final class GuestCredential: HTTPCredential {
    static func make(user: String, password: String, persistence: Int32) -> GuestCredential { GuestCredential() }
    func user() -> String { "guest" }
    func persistence() -> Int32 { 0 }
}
