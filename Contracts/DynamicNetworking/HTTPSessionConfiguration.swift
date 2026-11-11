import DynamicRuntime

/// Settings shared by a session's tasks (`URLSessionConfiguration`,
/// OkHttp `OkHttpClient.Builder`). Copied when the session is made.
@DynamicRuntime("org.pureswift.network.HTTPSessionConfiguration")
public protocol HTTPSessionConfiguration: AnyObject {

    /// Persistent cookies and cache.
    static func makeDefault() -> Self

    /// Cookies and cache in memory only, discarded with the session.
    static func makeEphemeral() -> Self

    /// Seconds a request may wait for data before failing with
    /// `.timedOut`. Default 60.
    func setTimeoutForRequest(_ seconds: Double)

    func timeoutForRequest() -> Double

    /// Seconds a whole task may take. Default 7 days on iOS; hosts without
    /// a limit enforce it themselves.
    func setTimeoutForResource(_ seconds: Double)

    func timeoutForResource() -> Double

    func setAllowsCellularAccess(_ allowed: Bool)

    /// Expensive networks: cellular and personal hotspots.
    func setAllowsExpensiveNetworkAccess(_ allowed: Bool)

    /// Constrained networks: Low Data Mode (iOS), Data Saver (Android).
    func setAllowsConstrainedNetworkAccess(_ allowed: Bool)

    /// Wait for connectivity instead of failing immediately with
    /// `.notConnectedToInternet`. The task delegate gets
    /// `taskIsWaitingForConnectivity`.
    func setWaitsForConnectivity(_ waits: Bool)

    /// Store cookies from responses and send them with requests.
    func setShouldSetCookies(_ enabled: Bool)

    /// An `HTTPCachePolicy` raw value for requests that don't set one.
    func setCachePolicy(_ policy: Int32)

    func setMaximumConnectionsPerHost(_ count: Int32)

    /// A header added to every request that doesn't set it; nil removes it.
    func setAdditionalHeader(_ name: String, value: String?)
}
