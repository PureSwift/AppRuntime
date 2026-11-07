import DynamicRuntime

/// A contract gated by a capability: hosts refuse `rt_class` for it unless
/// the app's manifest declares `.bluetooth`.
@DynamicRuntime("org.pureswift.example.Beacon", requires: .bluetooth)
public protocol Beacon: AnyObject {

    static func make() -> Self

    func identifier() -> String
}
