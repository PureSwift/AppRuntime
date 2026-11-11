#if !EMBEDDED_NO_CONCURRENCY
import DynamicRuntime
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// One activity classification.
public struct ActivitySample: Equatable, Sendable {

    public var activity: MotionActivity

    public var confidence: ActivityConfidence

    /// Host wall-clock milliseconds.
    public var timestamp: Int64

    public init(activity: MotionActivity, confidence: ActivityConfidence, timestamp: Int64) {
        self.activity = activity
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Async/await over `ActivityRecognizer` (§6.2.1): the guest-side
/// convenience layer.
///
/// `authorization` never prompts; `requestAuthorization()` is the only call
/// that does. One update stream at a time. The guest is single-threaded
/// (§6.4).
public final class AsyncActivityRecognizer: @unchecked Sendable {

    /// The underlying contract object.
    public let recognizer: any ActivityRecognizer

    let events: ActivityEvents

    public init() {
        let events = ActivityEvents()
        self.events = events
        self.recognizer = ActivityRecognizerProxy.make(events)
    }

    /// Whether this host classifies activity, with the capability granted.
    public static var isAvailable: Bool {
        ActivityRecognizerProxy.isAvailable && ActivityRecognizerProxy.isAvailable()
    }

    /// The current authorization. Never prompts.
    public static var authorization: MotionAuthorization {
        MotionAuthorization(rawValue: ActivityRecognizerProxy.authorizationStatus()) ?? .notDetermined
    }

    /// Prompts for access if it hasn't been decided, and returns the
    /// outcome. Returns the current authorization if the task is cancelled.
    public func requestAuthorization() async -> MotionAuthorization {
        let current = Self.authorization
        guard current == .notDetermined else { return current }
        return await withCallback { (callback: Callback<MotionAuthorization, Never>) in
            events.authorization.append(callback)
            recognizer.requestAuthorization()
        } onCancel: { callback in
            callback.resume(returning: Self.authorization)
        }
    }

    /// Classifications as they change, until the stream is released or its
    /// task is cancelled.
    public func updates() -> EventStream<ActivitySample, MotionError> {
        let (stream, continuation) = EventStream<ActivitySample, MotionError>.makeStream()
        events.updates?.finish()
        events.generation &+= 1
        let generation = events.generation
        events.updates = continuation
        continuation.onTermination = { [events, recognizer] in
            guard events.generation == generation else { return }
            events.updates = nil
            recognizer.stopUpdates()
        }
        recognizer.startUpdates()
        return stream
    }
}

/// The delegate behind `AsyncActivityRecognizer`.
final class ActivityEvents: ActivityRecognizerDelegate {

    let authorization = PendingCallbacks<MotionAuthorization, Never>()

    var updates: EventStream<ActivitySample, MotionError>.Continuation?

    var generation = 0

    func didChangeAuthorization(_ recognizer: any ActivityRecognizer, status: Int32) {
        let status = MotionAuthorization(rawValue: status) ?? .notDetermined
        guard status != .notDetermined else { return }
        authorization.resumeAll(with: .success(status))
        if status == .denied || status == .restricted {
            updates?.finish(throwing: .unauthorized)
        }
    }

    func didUpdateActivity(_ recognizer: any ActivityRecognizer, activity: Int32, confidence: Int32, timestamp: Int64) {
        updates?.yield(ActivitySample(
            activity: MotionActivity(rawValue: activity),
            confidence: ActivityConfidence(rawValue: confidence) ?? .low,
            timestamp: timestamp
        ))
    }

    func didFail(_ recognizer: any ActivityRecognizer, error: Int32) {
        updates?.finish(throwing: MotionError(code: error) ?? .unknown)
    }
}
#endif
