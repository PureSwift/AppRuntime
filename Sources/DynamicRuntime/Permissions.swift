/// The built-in `Permissions` contract (§7.4): one way to ask for any
/// capability.
///
/// Every host provides it. Contracts keep their own `request…` methods for
/// contract-specific options, such as `LocationManager`'s background access.
///
/// ```swift
/// if try PermissionsProxy.status(.location) == PermissionStatus.notDetermined.rawValue {
///     try PermissionsProxy.request(.location, delegate: self)
/// }
/// ```
///
/// A host reports `.denied` for a capability the app's manifest doesn't
/// declare, and `.unavailable` for one the device or platform lacks.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | each framework's authorization API (`CLLocationManager`, `CBManager`, `AVCaptureDevice`, `UNUserNotificationCenter`, …) |
/// | Android | runtime permissions (`checkSelfPermission`, `requestPermissions`) |
/// | Linux | the matching portal or service, else granted |
@DynamicRuntime("org.pureswift.runtime.Permissions")
public protocol Permissions: AnyObject {

    /// A `PermissionStatus` raw value. Never prompts.
    static func status(_ capability: Capability) throws(RuntimeError) -> Int32

    /// Asks for `capability`, prompting if the user hasn't decided. The
    /// result arrives through `delegate`, which the host holds until then,
    /// at once when there's nothing to ask.
    static func request(_ capability: Capability, delegate: PermissionsDelegate) throws(RuntimeError)
}

/// The result of a `Permissions` request.
@DynamicCallback("org.pureswift.runtime.PermissionsDelegate")
public protocol PermissionsDelegate: AnyObject {

    /// `status` is a `PermissionStatus` raw value.
    func didRequest(_ capability: Capability, status: Int32)
}

/// `Permissions.status(_:)`.
public enum PermissionStatus: Int32, Sendable {

    /// The user hasn't been asked.
    case notDetermined = 0

    /// Parental controls or device management prevent access.
    case restricted = 1

    /// The user refused, or the app's manifest doesn't declare the
    /// capability.
    case denied = 2

    case granted = 3

    /// Granted in part: approximate location only, selected photos only,
    /// provisional notifications.
    case limited = 4

    /// The device or platform lacks the capability.
    case unavailable = 5
}
