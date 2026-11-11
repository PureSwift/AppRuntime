/// Guest-side names for the integer codes the Networking contracts carry.

/// `HTTPTask.state()`.
public enum HTTPTaskState: Int32, Sendable {
    case running = 0
    /// Created and not resumed yet.
    case suspended = 1
    /// `cancel()` was called; completion is pending.
    case canceling = 2
    case completed = 3
}

/// Request cache policies (`URLRequest.CachePolicy`; OkHttp `CacheControl`).
public enum HTTPCachePolicy: Int32, Sendable {
    /// Follow the response's cache headers.
    case useProtocolCachePolicy = 0
    case reloadIgnoringLocalCacheData = 1
    case returnCacheDataElseLoad = 2
    /// Offline: fail with `.resourceUnavailable` if nothing is cached.
    case returnCacheDataDontLoad = 3
}

/// `HTTPTaskDelegate.didReceiveChallenge` methods.
public enum HTTPAuthenticationMethod: Int32, Sendable {
    case basic = 0
    case digest = 1
    /// A proxy asking for Basic credentials.
    case proxyBasic = 2
    /// A scheme the guest can't answer with a password (NTLM, Negotiate).
    case other = 3
}

/// `HTTPCredential` persistence.
public enum HTTPCredentialPersistence: Int32, Sendable {
    /// Use for this request only.
    case none = 0
    /// Keep for the session.
    case forSession = 1
    /// Store in the platform's credential storage (Keychain on iOS).
    case permanent = 2
}

/// `HTTPTaskDelegate.didComplete` codes. `0` is success.
public enum NetworkError: Int32, Error, Sendable {
    case unknown = 1
    case cancelled = 2
    case invalidURL = 3
    case timedOut = 4
    case cannotFindHost = 5
    case cannotConnectToHost = 6
    case connectionLost = 7
    case notConnectedToInternet = 8
    /// Cellular, expensive or constrained access was disallowed by the
    /// configuration.
    case networkAccessNotAllowed = 9
    case secureConnectionFailed = 10
    /// The server's certificate isn't trusted. Hosts don't let guests
    /// override trust.
    case serverCertificateUntrusted = 11
    /// Plain `http` blocked by iOS App Transport Security or Android's
    /// cleartext policy; the manifest must allow the domain.
    case insecureConnectionNotAllowed = 12
    /// iOS 14+: the user denied local network access, which the system
    /// asks for on the first request to a LAN address.
    case localNetworkDenied = 13
    case tooManyRedirects = 14
    case badServerResponse = 15
    case userAuthenticationRequired = 16
    /// Nothing cached for `.returnCacheDataDontLoad`.
    case resourceUnavailable = 17
    /// The session was invalidated before the task ran.
    case sessionInvalidated = 18
}

public extension NetworkError {

    /// The error for a delegate `error` code: `nil` for `0`, success; codes
    /// this version doesn't know are `unknown`.
    init?(code: Int32) {
        guard code != 0 else { return nil }
        self = NetworkError(rawValue: code) ?? .unknown
    }
}
