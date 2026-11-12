import DynamicRuntime

/// The user's current activity: stationary, walking, running, driving or
/// cycling.
///
/// Permissions first, as for `Pedometer`. On Android, activity recognition
/// comes from Google Play services; without them `isAvailable()` is
/// `false`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS | `CMMotionActivityManager` |
/// | Android | `ActivityRecognitionClient` transition updates |
@DynamicRuntime("org.pureswift.motion.ActivityRecognizer", requires: .motion)
public protocol ActivityRecognizer: AnyObject {

    static func isAvailable() -> Bool

    /// A `MotionAuthorization` raw value. Never prompts.
    static func authorizationStatus() -> Int32

    /// Never prompts.
    static func make(_ delegate: ActivityRecognizerDelegate) -> Self

    func requestAuthorization()

    func startUpdates()

    func stopUpdates()
}
