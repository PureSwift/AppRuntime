import DynamicRuntime
import RuntimeABI

/// The built-in `Permissions` contract, routing each capability to the
/// `PermissionProvider` of the module whose service gates it.
///
/// - A capability the app doesn't declare is `denied`.
/// - A declared capability no module covers is `unavailable`.
///
/// `AppHost.prepare` sets `declared` and `providers`; register it with
/// `PermissionsProxy.register(HostPermissions.self, in:)`.
public final class HostPermissions: Permissions {

    /// The app's declared capabilities, from `RTCapabilities`.
    nonisolated(unsafe) public static var declared: Set<Capability> = []

    nonisolated(unsafe) public static var providers: [Capability: any PermissionProvider] = [:]

    public static func status(_ capability: Capability) -> Int32 {
        provider(for: capability).status().rawValue
    }

    public static func request(_ capability: Capability, delegate: any PermissionsDelegate) {
        // The provider calls back later, on the main thread; the closure
        // holds the delegate until then.
        provider(for: capability).request { status in
            delegate.didRequest(capability, status: status.rawValue)
        }
    }

    /// What answers for `capability`.
    public static func provider(for capability: Capability) -> any PermissionProvider {
        guard declared.contains(capability) else {
            return DeniedPermission()
        }
        return providers[capability] ?? UnavailablePermission()
    }
}
