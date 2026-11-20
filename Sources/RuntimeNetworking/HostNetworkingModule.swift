import Dispatch
import DynamicNetworking
import DynamicRuntime
import RuntimeHost
import RuntimeNative

/// The networking contracts (`DynamicNetworking`) over Swift Foundation's
/// `URLSession`, for any host written in Swift: `HostHTTPSession`,
/// `HostHTTPSessionConfiguration`, `HostHTTPRequest`, `HostHTTPResponse`,
/// `HostHTTPTask`, `HostHTTPCredential` and `HostURL`.
///
/// ```swift
/// HostNetworkingModule.register(in: runtime)
/// ```
///
/// On Apple platforms `URLSession` is the system's; elsewhere it's
/// swift-corelibs-foundation's `FoundationNetworking`, over libcurl. Each
/// session's callbacks arrive on a queue of its own and are carried to the
/// main thread by `deliver`, the only thread the guest is entered from.
///
/// `.network` is granted by the host itself, so this module has no
/// permission providers.
public enum HostNetworkingModule: HostModule {

    /// Told what the contracts couldn't do as a guest asked, such as a
    /// failure they have no code for or a session that can't be
    /// invalidated. Nil, the default, drops it. Set it before the guest
    /// runs; it's called on the main thread.
    ///
    /// ```swift
    /// HostNetworkingModule.log = { logger.error("\($0, privacy: .public)") }
    /// ```
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    /// Runs URLSession's callbacks on the main thread. The default is the
    /// main dispatch queue; a host with a loop of its own posts to that.
    /// Set it before the guest runs: a session keeps the one it was made
    /// with.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = onMain

    static let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }

    public static var contracts: [ContractDescriptor] {
        [
            HTTPSessionProxy.descriptor,
            HTTPSessionConfigurationProxy.descriptor,
            HTTPRequestProxy.descriptor,
            HTTPResponseProxy.descriptor,
            HTTPTaskProxy.descriptor,
            HTTPTaskDelegateProxy.descriptor,
            HTTPCredentialProxy.descriptor,
            ParsedURLProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        if let native = registrar as? NativeRuntime {
            self.native = native
        }
        HTTPSessionProxy.register(HostHTTPSession.self, in: registrar)
        HTTPSessionConfigurationProxy.register(HostHTTPSessionConfiguration.self, in: registrar)
        HTTPRequestProxy.register(HostHTTPRequest.self, in: registrar)
        HTTPResponseProxy.register(HostHTTPResponse.self, in: registrar)
        HTTPTaskProxy.register(HostHTTPTask.self, in: registrar)
        HTTPCredentialProxy.register(HostHTTPCredential.self, in: registrar)
        ParsedURLProxy.register(HostURL.self, in: registrar)
        HTTPTaskDelegateProxy.registerInterface(in: registrar)
    }

    /// The runtime the guest's proxies come from, for recovering this
    /// module's own objects from them (`host(_:as:)`). The last
    /// `NativeRuntime` registered with, else `NativeRuntime.shared`.
    nonisolated(unsafe) static var native: NativeRuntime?

    /// The object of this module behind `value`.
    ///
    /// Objects the guest passes back, such as a configuration, a request or a
    /// credential, arrive as proxies even when this module made them. Some
    /// contracts can't be read back through their protocol (a credential's
    /// password is write-only), so the implementation recovers its own
    /// object. Returns `nil` for an object implemented elsewhere, such as by
    /// the guest.
    static func host<T: AnyObject>(_ value: AnyObject, as type: T.Type) -> T? {
        if let object = value as? T {
            return object
        }
        guard let proxy = value as? DynamicObject else {
            return nil
        }
        return (native ?? .shared).swiftObject(for: proxy) as? T
    }
}

/// Runs `body` in an autorelease pool where there is one (Apple platforms),
/// so what a guest's call autoreleases goes with it; elsewhere just runs it.
func autoreleasing<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}
