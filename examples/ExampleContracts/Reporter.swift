import DynamicRuntime

/// Collects the example app's results on the host, so the same app can be
/// checked in native and wasm mode.
@DynamicRuntime("org.pureswift.example.Reporter")
public protocol Reporter: AnyObject {

    static func make() -> Self

    func record(_ line: String)
}
