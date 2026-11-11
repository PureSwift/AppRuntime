import DynamicRuntime

/// Receives `ActivityRecognizer` events on the main thread.
@DynamicCallback("org.pureswift.motion.ActivityRecognizerDelegate")
public protocol ActivityRecognizerDelegate: AnyObject {

    /// `status` is a `MotionAuthorization` raw value.
    func didChangeAuthorization(_ recognizer: ActivityRecognizer, status: Int32)

    /// `activity` is a `MotionActivity` raw value (several flags may be set,
    /// for example automotive and stationary at a red light), `confidence`
    /// an `ActivityConfidence` raw value, `timestamp` milliseconds since
    /// 1970 UTC.
    func didUpdateActivity(_ recognizer: ActivityRecognizer, activity: Int32, confidence: Int32, timestamp: Int64)

    /// `error` is a `MotionError` raw value. Updates have stopped.
    func didFail(_ recognizer: ActivityRecognizer, error: Int32)
}
