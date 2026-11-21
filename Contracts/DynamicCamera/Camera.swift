import DynamicFiles
import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A camera: a live preview, photos, and video with sound. Show what it
/// sees with `CameraPreview(camera)`; without a view it still runs, and
/// can take a photo.
///
/// ```swift
/// let camera = Camera()
/// guard await Camera.requestAccess() == .authorized else { return }
/// camera.start(.back)
/// let photo = try await camera.capturePhoto(to: .caches / "shot.jpg")
/// ```
///
/// It's observable: a view that reads `state`, `zoomFactor` or
/// `recordingDuration` is updated when they change.
///
/// The camera lives in the host (`CameraCapture`), which is made the first
/// time it's used. No frame crosses to the guest: a capture is a file, at
/// a path the app names in its own directories. Releasing the `Camera`
/// turns it off. One camera is on at a time, and only while the app is in
/// front.
///
/// It's guest-side only. The guest is single-threaded (§6.4).
public final class Camera: Observable {

    // MARK: The device

    /// The cameras this device has.
    public static var positions: [CameraPosition] {
        let bits = CameraCaptureProxy.positions()
        return [CameraPosition.back, .front, .external].filter { bits & $0.rawValue != 0 }
    }

    /// Whether the app may use the camera now. Never asks.
    public static var access: CameraAccess {
        // An access from a newer host isn't one to rely on.
        CameraAccess(rawValue: CameraCaptureProxy.access()) ?? .denied
    }

    /// Whether the app may record sound now. Never asks.
    public static var microphoneAccess: CameraAccess {
        CameraAccess(rawValue: CameraCaptureProxy.microphoneAccess()) ?? .denied
    }

    /// Asks the user for the camera if they haven't decided, and gives
    /// what the app has afterwards.
    public static func requestAccess(completion: @escaping (CameraAccess) -> Void) {
        CameraCaptureProxy.requestAccess(AccessReceiver(microphone: false, completion))
    }

    /// Asks the user for the microphone, for a video with sound. It needs
    /// `.microphone` in the manifest.
    public static func requestMicrophoneAccess(completion: @escaping (CameraAccess) -> Void) {
        CameraCaptureProxy.requestMicrophoneAccess(AccessReceiver(microphone: true, completion))
    }

    // MARK: State

    public var state: CameraState {
        registrar.access(self, propertyIndex: 0)
        return values.state
    }

    /// Which camera is on, or was last.
    public var position: CameraPosition {
        registrar.access(self, propertyIndex: 1)
        return values.position
    }

    /// 1 is the main lens. A phone's wide and telephoto lenses are the
    /// ends of the range: the host changes lens as the zoom crosses from
    /// one to the next. Setting it is clamped to `zoomRange`; a pinch on
    /// the preview changes it too.
    public var zoomFactor: Double {
        get {
            registrar.access(self, propertyIndex: 2)
            return values.zoomFactor
        }
        set {
            // A camera that's off has no zoom to set.
            guard values.state == .running, newValue.isFinite else { return }
            capture.setZoom(newValue)
        }
    }

    /// What this camera can zoom to, such as `0.5...15`.
    public var zoomRange: ClosedRange<Double> {
        registrar.access(self, propertyIndex: 3)
        return values.zoomRange
    }

    public var hasFlash: Bool {
        registrar.access(self, propertyIndex: 4)
        return values.hasFlash
    }

    /// For photos, where the camera has a flash.
    public var flashMode: CameraFlashMode {
        get {
            registrar.access(self, propertyIndex: 5)
            return values.flashMode
        }
        set {
            guard newValue != values.flashMode else { return }
            mutate(5) { values.flashMode = newValue }
            capture.setFlashMode(newValue.rawValue)
        }
    }

    public var isRecording: Bool {
        registrar.access(self, propertyIndex: 6)
        return values.isRecording
    }

    /// Seconds into the recording. Exact when read; for views it changes
    /// once a second. After a recording, its length.
    public var recordingDuration: Double {
        registrar.access(self, propertyIndex: 7)
        return durationNow()
    }

    /// Why it's `.failed`.
    public var error: CameraError? {
        registrar.access(self, propertyIndex: 8)
        return values.error
    }

    /// Called with the video when a recording ends, however it ended:
    /// stopped by the app, or cut short because the camera was
    /// interrupted or stopped, or the disk filled. The file is kept.
    public var onRecordingFinished: ((CapturedVideo) -> Void)?

    public init() { }

    deinit {
        receiver.camera = nil
    }

    /// What a `CameraPreview` node carries to say which camera it shows.
    public var identifier: Int32 {
        if let cachedIdentifier {
            return cachedIdentifier
        }
        let identifier = capture.identifier()
        cachedIdentifier = identifier
        return identifier
    }

    // MARK: Running

    /// Turns on the back or the front camera. On one that's running, it
    /// switches. Without access it fails: `state` is `.failed`, and
    /// `error` is `notAuthorized`.
    public func start(_ position: CameraPosition = .back) {
        capture.start(position.rawValue)
    }

    public func stop() {
        // Nothing made means nothing to turn off.
        made?.stop()
    }

    // MARK: Photos

    /// Takes a photo: a JPEG, at the camera's full size and upright,
    /// written to `file`, replacing what's there. One at a time: a second
    /// while one is being taken fails with `busy`, and so does one during
    /// a recording.
    public func capturePhoto(to file: FilePath, completion: @escaping (Result<CapturedPhoto, CameraError>) -> Void) {
        let request = makeRequest()
        photos[request] = (file, completion)
        capture.capturePhoto(file.directory.rawValue, path: file.path, request: request)
    }

    // MARK: Video

    /// Starts recording to `file`: MP4 where the host can. `completion`
    /// hears when recording has begun. With `audio`, it needs
    /// `.microphone` in the manifest and the user's leave; without
    /// either it fails with `notAuthorized`, and nothing is recorded.
    public func startRecording(to file: FilePath, audio: Bool = true, completion: @escaping (Result<Void, CameraError>) -> Void) {
        let request = makeRequest()
        starts[request] = (file, completion)
        capture.startRecording(file.directory.rawValue, path: file.path, audio: audio, request: request)
    }

    /// Ends the recording. `completion` hears when the file is whole.
    public func stopRecording(completion: @escaping (Result<CapturedVideo, CameraError>) -> Void) {
        guard recording != nil else {
            completion(.failure(.notRunning))
            return
        }
        guard stopping == nil else {
            completion(.failure(.busy))
            return
        }
        stopping = completion
        capture.stopRecording()
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) static func requestAccess() async -> CameraAccess {
        await withCallback { (callback: Callback<CameraAccess, Never>) in
            requestAccess { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: .denied)
        }
    }

    public nonisolated(nonsending) static func requestMicrophoneAccess() async -> CameraAccess {
        await withCallback { (callback: Callback<CameraAccess, Never>) in
            requestMicrophoneAccess { callback.resume(returning: $0) }
        } onCancel: { callback in
            callback.resume(returning: .denied)
        }
    }

    public nonisolated(nonsending) func capturePhoto(to file: FilePath) async throws(CameraError) -> CapturedPhoto {
        try await wait { self.capturePhoto(to: file, completion: $0) }
    }

    /// Returns when recording has begun.
    public nonisolated(nonsending) func startRecording(to file: FilePath, audio: Bool = true) async throws(CameraError) {
        try await wait { self.startRecording(to: file, audio: audio, completion: $0) }
    }

    /// Returns when the file is whole.
    @discardableResult
    public nonisolated(nonsending) func stopRecording() async throws(CameraError) -> CapturedVideo {
        try await wait { self.stopRecording(completion: $0) }
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the capture itself goes on.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, CameraError>) -> Void) -> Void) async throws(CameraError) -> Value {
        try await withCallback { (callback: Callback<Value, CameraError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif

    // MARK: The host's camera

    private struct Values {
        var state = CameraState.stopped
        var position = CameraPosition.back
        var zoomFactor = 1.0
        var zoomRange: ClosedRange<Double> = 1 ... 1
        var hasFlash = false
        var flashMode = CameraFlashMode.off
        var isRecording = false
        var error: CameraError?
    }

    private let registrar = ObservationRegistrar()

    private var values = Values()

    private let receiver = Receiver()

    private var made: (any CameraCapture)?

    private var cachedIdentifier: Int32?

    private var nextRequest: Int32 = 1

    /// The photos asked for and not yet answered.
    private var photos: [Int32: (file: FilePath, completion: (Result<CapturedPhoto, CameraError>) -> Void)] = [:]

    /// The recordings asked for that haven't begun.
    private var starts: [Int32: (file: FilePath, completion: (Result<Void, CameraError>) -> Void)] = [:]

    /// The recording under way: its request, its file, and when it began
    /// on the clock.
    private var recording: (request: Int32, file: FilePath, timestamp: Int64)?

    /// Who waits for the recording to end.
    private var stopping: ((Result<CapturedVideo, CameraError>) -> Void)?

    /// The last recording's length.
    private var lastDuration = 0.0

    /// Counts recordings, so a timer left over from one says nothing of
    /// the next.
    private var ticking = 0

    private var capture: any CameraCapture {
        if let made {
            return made
        }
        receiver.camera = Unmanaged.passUnretained(self)
        let capture = CameraCaptureProxy.make(receiver)
        made = capture
        return capture
    }

    private func mutate(_ index: Int, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: index, change)
    }

    private func makeRequest() -> Int32 {
        let request = nextRequest
        nextRequest = nextRequest == .max ? 1 : nextRequest + 1
        return request
    }

    /// How long the recording has run, from when it began and the clock.
    private func durationNow() -> Double {
        guard let recording, let now = try? RuntimeClock.now() else {
            return lastDuration
        }
        return max(Double(now - recording.timestamp) / 1_000_000_000, 0)
    }

    /// Tells views the duration moved, once a second while recording.
    private func tick(_ generation: Int) {
        // A host with no clock has no ticks.
        try? RuntimeClock.after(nanoseconds: 1_000_000_000) { [receiver] in
            guard let camera = receiver.camera?.takeUnretainedValue(), camera.ticking == generation, camera.recording != nil else {
                return
            }
            camera.mutate(7) { }
            camera.tick(generation)
        }
    }

    // MARK: From the host

    fileprivate func changed(state: Int32) {
        // A state from a newer host changes nothing here.
        guard let state = CameraState(rawValue: state), state != values.state else { return }
        if state == .starting || state == .running, values.error != nil {
            mutate(8) { values.error = nil }
        }
        mutate(0) { values.state = state }
    }

    fileprivate func started(position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) {
        if let position = CameraPosition(rawValue: position), position != values.position {
            mutate(1) { values.position = position }
        }
        var range: ClosedRange<Double> = 1 ... 1
        if minimumZoom.isFinite, maximumZoom.isFinite, minimumZoom > 0, minimumZoom <= maximumZoom {
            range = minimumZoom ... maximumZoom
        }
        if range != values.zoomRange {
            mutate(3) { values.zoomRange = range }
        }
        if values.zoomFactor != 1 {
            mutate(2) { values.zoomFactor = 1 }
        }
        if hasFlash != values.hasFlash {
            mutate(4) { values.hasFlash = hasFlash }
        }
    }

    fileprivate func changed(zoom factor: Double) {
        guard factor.isFinite, factor != values.zoomFactor else { return }
        mutate(2) { values.zoomFactor = factor }
    }

    fileprivate func failed(_ error: CameraError) {
        mutate(8) { values.error = error }
    }

    fileprivate func captured(_ request: Int32, width: Int32, height: Int32) {
        guard let photo = photos.removeValue(forKey: request) else { return }
        photo.completion(.success(CapturedPhoto(path: photo.file, width: Int(max(width, 0)), height: Int(max(height, 0)))))
    }

    fileprivate func recordingStarted(_ request: Int32, timestamp: Int64) {
        guard let start = starts.removeValue(forKey: request) else { return }
        recording = (request, start.file, timestamp)
        ticking &+= 1
        lastDuration = 0
        mutate(6) { values.isRecording = true }
        mutate(7) { }
        tick(ticking)
        start.completion(.success(()))
    }

    fileprivate func recordingFinished(_ request: Int32, duration: Double, mimeType: String, error: Int32) {
        guard let recording, recording.request == request else { return }
        let video = CapturedVideo(
            path: recording.file,
            duration: duration.isFinite ? max(duration, 0) : 0,
            contentType: mimeType,
            interruption: error == 0 ? nil : CameraError(rawValue: error) ?? .unknown
        )
        self.recording = nil
        ticking &+= 1
        lastDuration = video.duration
        mutate(6) { values.isRecording = false }
        mutate(7) { }
        let stopping = self.stopping
        self.stopping = nil
        stopping?(.success(video))
        onRecordingFinished?(video)
    }

    fileprivate func captureFailed(_ request: Int32, error: CameraError) {
        if let photo = photos.removeValue(forKey: request) {
            photo.completion(.failure(error))
        } else if let start = starts.removeValue(forKey: request) {
            start.completion(.failure(error))
        }
    }
}

/// The delegate the host holds. It doesn't keep the camera alive: the
/// camera owns the host's `CameraCapture`, which owns this, and the camera
/// clears the reference when it's released. Embedded Swift has no weak
/// references.
private final class Receiver: CameraCaptureDelegate {

    var camera: Unmanaged<Camera>?

    private var current: Camera? {
        camera?.takeUnretainedValue()
    }

    func didChangeAccess(_ access: Int32, microphone: Bool) { }

    func didChangeState(_ state: Int32) {
        current?.changed(state: state)
    }

    func didStart(_ position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) {
        current?.started(position: position, minimumZoom: minimumZoom, maximumZoom: maximumZoom, hasFlash: hasFlash)
    }

    func didChangeZoom(_ factor: Double) {
        current?.changed(zoom: factor)
    }

    func didFail(_ error: Int32) {
        current?.failed(CameraError(rawValue: error) ?? .unknown)
    }

    func didCapturePhoto(_ request: Int32, width: Int32, height: Int32) {
        current?.captured(request, width: width, height: height)
    }

    func didStartRecording(_ request: Int32, timestamp: Int64) {
        current?.recordingStarted(request, timestamp: timestamp)
    }

    func didFinishRecording(_ request: Int32, duration: Double, mimeType: String, error: Int32) {
        current?.recordingFinished(request, duration: duration, mimeType: mimeType, error: error)
    }

    func didFailCapture(_ request: Int32, error: Int32) {
        current?.captureFailed(request, error: CameraError(rawValue: error) ?? .unknown)
    }
}

/// The delegate of one question put to the user. The host holds it until
/// it answers.
private final class AccessReceiver: CameraCaptureDelegate {

    private let microphone: Bool

    private var finish: ((CameraAccess) -> Void)?

    init(microphone: Bool, _ finish: @escaping (CameraAccess) -> Void) {
        self.microphone = microphone
        self.finish = finish
    }

    /// Only a host's first answer counts, and only one to the question
    /// that was asked.
    func didChangeAccess(_ access: Int32, microphone: Bool) {
        guard microphone == self.microphone, let finish else { return }
        self.finish = nil
        finish(CameraAccess(rawValue: access) ?? .denied)
    }

    func didChangeState(_ state: Int32) { }
    func didStart(_ position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) { }
    func didChangeZoom(_ factor: Double) { }
    func didFail(_ error: Int32) { }
    func didCapturePhoto(_ request: Int32, width: Int32, height: Int32) { }
    func didStartRecording(_ request: Int32, timestamp: Int64) { }
    func didFinishRecording(_ request: Int32, duration: Double, mimeType: String, error: Int32) { }
    func didFailCapture(_ request: Int32, error: Int32) { }
}
