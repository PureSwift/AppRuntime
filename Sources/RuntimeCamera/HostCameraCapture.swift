import Dispatch
import DynamicCamera
import DynamicFiles
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// One of the platform's cameras: an `AVCaptureSession`, a CameraX use
/// case group, a GStreamer pipeline. Everything is called on the main
/// thread.
///
/// It reports what happens to the `HostCameraCapture` it was made for, on
/// the main thread: `started` or `failed` after `start`, `zoomChanged`
/// when the user pinches, `interruptionBegan` and `interruptionEnded` when
/// the system takes the camera and gives it back, and `recordingFinished`
/// when a recording's file is whole.
public protocol CameraEngine: AnyObject {

    /// Turns the camera at `position` on, at a zoom of 1, switching from
    /// whichever was on; then calls `started` or `failed`.
    func start(_ position: CameraPosition)

    /// Turns the camera off. A recording under way is finished first, and
    /// still reported.
    func stop()

    /// A factor inside the range the engine reported.
    func setZoom(_ factor: Double)

    func setFlashMode(_ mode: CameraFlashMode)

    /// Writes a JPEG at an absolute path, upright, off the main thread,
    /// and answers on it, once, with the upright picture's pixels.
    func capturePhoto(to path: String, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void)

    /// Starts recording to an absolute path, with sound if `audio`.
    /// Answers `nil` when recording has begun.
    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void)

    /// Ends the recording; then calls `recordingFinished`.
    func stopRecording()
}

/// The platform's side of the camera: which cameras there are, the user's
/// leave, and the engines. Everything is called on the main thread.
public protocol CameraPlatform: AnyObject {

    /// The cameras this device has.
    var positions: [CameraPosition] { get }

    /// What the user has granted, as the platform says now.
    var access: CameraAccess { get }

    var microphoneAccess: CameraAccess { get }

    /// Asks the user, and says what they granted.
    func requestAccess(_ completion: @escaping (CameraAccess) -> Void)

    func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void)

    /// A camera that's off, which reports to `camera`.
    func makeEngine(for camera: HostCameraCapture) -> any CameraEngine
}

/// The `CameraCapture` contract over a host's `CameraPlatform`: what every
/// host written in Swift shares.
///
/// It finds each file through `HostFiles` before an engine sees a path,
/// and refuses one the app may not write; keeps one camera on, one photo
/// at a time and one recording, and answers each request once; refuses
/// sound without the capability and the user's leave; clamps the zoom;
/// and turns the camera off for the background and on again, ending a
/// recording when it must.
///
/// ```swift
/// HostCameraCapture.platform = MyCameras()
/// HostCameraCapture.allowsMicrophone = declared.contains(.microphone)
/// HostCameraCapture.clock = runtime.clock
/// HostCameraModule.register(in: runtime)
///
/// // From the platform:
/// HostCameraCapture.applicationDidEnterBackground()
/// HostCameraCapture.applicationWillEnterForeground()
/// // For a `CameraPreview` node's `camera` prop:
/// let engine = HostCameraCapture.camera(for: identifier)?.engine
/// ```
///
/// Without a platform there's no camera: `positions` is none, access is
/// `unavailable`, and `start` fails. Main thread only.
public final class HostCameraCapture: CameraCapture {

    // MARK: The host's settings

    /// The platform's cameras.
    nonisolated(unsafe) public static var platform: (any CameraPlatform)?

    /// Whether the manifest declares `.microphone`: a video with sound
    /// needs it.
    nonisolated(unsafe) public static var allowsMicrophone = false

    /// The clock the guest's `Clock` contract reads, so the time a
    /// recording began is on its timeline.
    nonisolated(unsafe) public static var clock: (any HostClock)?

    nonisolated(unsafe) private static var cameras: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    /// The camera that's on, or would be if the app were in front.
    nonisolated(unsafe) private static weak var active: HostCameraCapture?

    nonisolated(unsafe) private static var isInBackground = false

    private struct Weak {
        weak var camera: HostCameraCapture?
    }

    // MARK: A camera

    private let delegate: any CameraCaptureDelegate

    /// The platform's camera, for whatever shows its preview.
    public private(set) var engine: (any CameraEngine)?

    private let number: Int32

    public private(set) var state = CameraState.stopped

    /// The camera asked for.
    public private(set) var position = CameraPosition.back

    private var zoomRange: ClosedRange<Double> = 1 ... 1

    private var hasFlash = false

    private var flashMode = CameraFlashMode.off

    /// The photo being taken.
    private var photoRequest: Int32?

    private enum Recording {
        case starting(Int32)
        case recording(Int32)
        /// Asked to end, and the file isn't whole yet.
        case ending(Int32)

        var request: Int32 {
            switch self {
            case .starting(let request), .recording(let request), .ending(let request): return request
            }
        }
    }

    private var recording: Recording?

    /// Why the recording that's ending was cut short, when it was.
    private var cutShort: CameraError?

    /// The system took the camera, and hasn't given it back.
    private var isInterruptedBySystem = false

    init(delegate: any CameraCaptureDelegate) {
        self.delegate = delegate
        self.number = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.cameras[number] = Weak(camera: self)
        self.engine = Self.platform?.makeEngine(for: self)
    }

    deinit {
        // The guest released it: the camera goes off, and a recording
        // ends with its file kept.
        if state != .stopped, state != .failed {
            if recording != nil {
                engine?.stopRecording()
            }
            engine?.stop()
        }
        Self.cameras[number] = nil
    }

    public static func make(_ delegate: any CameraCaptureDelegate) -> HostCameraCapture {
        HostCameraCapture(delegate: delegate)
    }

    // MARK: The device and the user's leave

    public static func positions() -> Int32 {
        (platform?.positions ?? []).reduce(0) { $0 | $1.rawValue }
    }

    /// What the app may do with the camera now.
    public static var effectiveAccess: CameraAccess {
        platform?.access ?? .unavailable
    }

    /// What the app may do with the microphone now: nothing, without the
    /// manifest's `.microphone`.
    public static var effectiveMicrophoneAccess: CameraAccess {
        guard let platform else { return .unavailable }
        return allowsMicrophone ? platform.microphoneAccess : .denied
    }

    public static func access() -> Int32 {
        effectiveAccess.rawValue
    }

    public static func microphoneAccess() -> Int32 {
        effectiveMicrophoneAccess.rawValue
    }

    /// Asks the user for the camera if they haven't decided, and says
    /// what the app has.
    public static func requestAccess(_ completion: @escaping (CameraAccess) -> Void) {
        guard let platform, platform.access == .notDetermined else {
            completion(effectiveAccess)
            return
        }
        var answered = false
        platform.requestAccess { _ in
            // A platform that answers twice is heard once.
            guard !answered else { return }
            answered = true
            completion(effectiveAccess)
        }
    }

    public static func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void) {
        guard let platform, allowsMicrophone, platform.microphoneAccess == .notDetermined else {
            completion(effectiveMicrophoneAccess)
            return
        }
        var answered = false
        platform.requestMicrophoneAccess { _ in
            guard !answered else { return }
            answered = true
            completion(effectiveMicrophoneAccess)
        }
    }

    public static func requestAccess(_ delegate: any CameraCaptureDelegate) {
        requestAccess { delegate.didChangeAccess($0.rawValue, microphone: false) }
    }

    public static func requestMicrophoneAccess(_ delegate: any CameraCaptureDelegate) {
        requestMicrophoneAccess { delegate.didChangeAccess($0.rawValue, microphone: true) }
    }

    public func identifier() -> Int32 {
        number
    }

    // MARK: Host side

    /// The camera a `CameraPreview` node names, while the guest holds it.
    public static func camera(for identifier: Int32) -> HostCameraCapture? {
        cameras[identifier]?.camera
    }

    /// Whether a camera is on: where a host that must say so says so.
    public static var isCameraOn: Bool {
        guard let active else { return false }
        return active.state == .starting || active.state == .running
    }

    /// The app left the front: the camera goes off, and a recording ends
    /// first.
    public static func applicationDidEnterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        active?.suspend()
    }

    /// The app is in front again: the camera that was on comes back.
    public static func applicationWillEnterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        active?.resume()
    }

    /// Forgets the platform and the settings, for tests and for a host
    /// that starts the guest again.
    public static func reset() {
        platform = nil
        allowsMicrophone = false
        clock = nil
        active = nil
        isInBackground = false
    }

    private static func now() -> Int64 {
        clock?.now() ?? Int64(clamping: DispatchTime.now().uptimeNanoseconds)
    }

    private func report(_ new: CameraState) {
        guard new != state else { return }
        state = new
        delegate.didChangeState(new.rawValue)
    }

    private func fail(_ error: CameraError) {
        endCaptures(because: .interrupted)
        if state == .starting || state == .running {
            // Whatever was on isn't left on behind a camera that failed.
            engine?.stop()
        }
        if Self.active === self {
            Self.active = nil
        }
        report(.failed)
        delegate.didFail(error.rawValue)
    }

    /// The camera is going off, or to another lens: a photo being taken
    /// isn't, and a recording ends with its file kept.
    private func endCaptures(because reason: CameraError?) {
        if let request = photoRequest {
            photoRequest = nil
            delegate.didFailCapture(request, error: CameraError.interrupted.rawValue)
        }
        switch recording {
        case .starting(let request):
            // It never began: there's no file to keep.
            recording = nil
            delegate.didFailCapture(request, error: CameraError.interrupted.rawValue)
            engine?.stopRecording()
        case .recording(let request):
            recording = .ending(request)
            cutShort = reason
            engine?.stopRecording()
        case .ending, nil:
            break
        }
    }

    /// Off, because the app isn't in front or the system took the camera.
    private func suspend() {
        guard state == .starting || state == .running else { return }
        endCaptures(because: .interrupted)
        engine?.stop()
        report(.interrupted)
    }

    /// On again, when nothing holds it off any more.
    private func resume() {
        guard state == .interrupted, !Self.isInBackground, !isInterruptedBySystem, let engine else { return }
        engine.start(position)
    }

    // MARK: From the engine

    /// The camera is on, at a zoom of 1.
    public func started(minimumZoom: Double, maximumZoom: Double, hasFlash: Bool) {
        guard state == .starting || state == .interrupted, Self.active === self else {
            // Stopped, or put off, while it was starting.
            engine?.stop()
            return
        }
        guard !Self.isInBackground, !isInterruptedBySystem else {
            engine?.stop()
            report(.interrupted)
            return
        }
        if minimumZoom.isFinite, maximumZoom.isFinite, minimumZoom > 0, minimumZoom <= maximumZoom {
            zoomRange = minimumZoom ... maximumZoom
        } else {
            zoomRange = 1 ... 1
        }
        self.hasFlash = hasFlash
        delegate.didStart(position.rawValue, minimumZoom: zoomRange.lowerBound, maximumZoom: zoomRange.upperBound, hasFlash: hasFlash)
        if hasFlash {
            engine?.setFlashMode(flashMode)
        }
        report(.running)
    }

    /// The camera couldn't be turned on, or broke.
    public func failed(_ error: CameraError) {
        guard state != .stopped, state != .failed else { return }
        fail(error)
    }

    /// The user pinched on the preview.
    public func zoomChanged(_ factor: Double) {
        guard state == .running, factor.isFinite else { return }
        delegate.didChangeZoom(min(max(factor, zoomRange.lowerBound), zoomRange.upperBound))
    }

    /// The system took the camera: a call, another app. The engine has
    /// stopped by itself.
    public func interruptionBegan() {
        guard !isInterruptedBySystem else { return }
        isInterruptedBySystem = true
        guard state == .starting || state == .running else { return }
        endCaptures(because: .interrupted)
        report(.interrupted)
    }

    /// The system gave the camera back.
    public func interruptionEnded() {
        guard isInterruptedBySystem else { return }
        isInterruptedBySystem = false
        resume()
    }

    /// A recording's file is whole. `error` is why the engine itself cut
    /// it short, such as a full disk.
    public func recordingFinished(duration: Double, mimeType: String, error: CameraError? = nil) {
        guard let recording else { return }
        if case .starting = recording {
            return
        }
        self.recording = nil
        let reason = error ?? cutShort
        cutShort = nil
        delegate.didFinishRecording(recording.request, duration: duration, mimeType: mimeType, error: reason?.rawValue ?? 0)
    }

    // MARK: The camera

    public func start(_ position: Int32) {
        guard let position = CameraPosition(rawValue: position), let platform = Self.platform, let engine else {
            fail(.unavailable)
            return
        }
        guard platform.access == .authorized else {
            fail(.notAuthorized)
            return
        }
        guard platform.positions.contains(position) else {
            fail(.unavailable)
            return
        }
        // One camera is on at a time.
        if let other = Self.active, other !== self {
            other.stop()
        }
        if state == .running || state == .starting {
            guard position != self.position || state == .starting else { return }
            // Another lens: what was being captured through this one ends.
            endCaptures(because: .interrupted)
        }
        self.position = position
        Self.active = self
        guard !Self.isInBackground, !isInterruptedBySystem else {
            // It starts when the app is in front.
            report(.interrupted)
            return
        }
        report(.starting)
        engine.start(position)
    }

    public func stop() {
        guard state != .stopped else { return }
        let wasOn = state == .starting || state == .running
        // The app stopped it: a recording that ends here wasn't cut short.
        endCaptures(because: nil)
        if wasOn {
            engine?.stop()
        }
        if Self.active === self {
            Self.active = nil
        }
        report(.stopped)
    }

    public func setZoom(_ factor: Double) {
        guard state == .running, factor.isFinite, let engine else { return }
        let clamped = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        engine.setZoom(clamped)
        delegate.didChangeZoom(clamped)
    }

    public func setFlashMode(_ mode: Int32) {
        // A mode from a newer guest is no flash.
        flashMode = CameraFlashMode(rawValue: mode) ?? .off
        if state == .running, hasFlash {
            engine?.setFlashMode(flashMode)
        }
    }

    // MARK: Captures

    /// Why nothing can be captured now, when nothing can.
    private var refusal: CameraError? {
        switch state {
        case .running: return photoRequest != nil || recording != nil ? .busy : nil
        case .interrupted: return .interrupted
        case .stopped, .starting, .failed: return .notRunning
        }
    }

    /// Where a capture goes, when the app may write there: the folders
    /// above it are made, as a write through `Files` makes them.
    private func destination(_ directory: Int32, _ path: String) -> String? {
        guard let found = try? HostFiles.path(of: directory, path: path, writing: true), HostFiles.kind(ofItemAt: found) != .directory else {
            return nil
        }
        guard (try? HostFiles.makeDirectories(aboveFile: found)) != nil else {
            return nil
        }
        return found
    }

    public func capturePhoto(_ directory: Int32, path: String, request: Int32) {
        if let refusal {
            delegate.didFailCapture(request, error: refusal.rawValue)
            return
        }
        guard let engine, let destination = destination(directory, path) else {
            delegate.didFailCapture(request, error: CameraError.writeFailed.rawValue)
            return
        }
        photoRequest = request
        engine.capturePhoto(to: destination) { [weak self] result in
            // Answered once: a camera that went off has answered already.
            guard let self, self.photoRequest == request else { return }
            self.photoRequest = nil
            switch result {
            case .success(let size):
                self.delegate.didCapturePhoto(request, width: Int32(clamping: size.width), height: Int32(clamping: size.height))
            case .failure(let error):
                self.delegate.didFailCapture(request, error: error.rawValue)
            }
        }
    }

    public func startRecording(_ directory: Int32, path: String, audio: Bool, request: Int32) {
        if let refusal {
            delegate.didFailCapture(request, error: refusal.rawValue)
            return
        }
        // Sound needs the capability and the user's leave. A silent video
        // isn't recorded instead.
        guard !audio || Self.effectiveMicrophoneAccess == .authorized else {
            delegate.didFailCapture(request, error: CameraError.notAuthorized.rawValue)
            return
        }
        guard let engine, let destination = destination(directory, path) else {
            delegate.didFailCapture(request, error: CameraError.writeFailed.rawValue)
            return
        }
        recording = .starting(request)
        engine.startRecording(to: destination, audio: audio) { [weak self] error in
            guard let self, case .starting(let starting)? = self.recording, starting == request else { return }
            if let error {
                self.recording = nil
                self.delegate.didFailCapture(request, error: error.rawValue)
            } else {
                self.recording = .recording(request)
                self.delegate.didStartRecording(request, timestamp: Self.now())
            }
        }
    }

    public func stopRecording() {
        guard case .recording(let request)? = recording, let engine else { return }
        recording = .ending(request)
        cutShort = nil
        engine.stopRecording()
    }
}

/// Camera access as the built-in `Permissions` contract reports it.
public final class CameraPermission: PermissionProvider {

    /// Whether this is the microphone's.
    let microphone: Bool

    public init(microphone: Bool = false) {
        self.microphone = microphone
    }

    static func status(_ access: CameraAccess) -> PermissionStatus {
        switch access {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .unavailable: return .unavailable
        }
    }

    public func status() -> PermissionStatus {
        Self.status(microphone ? HostCameraCapture.effectiveMicrophoneAccess : HostCameraCapture.effectiveAccess)
    }

    public func request(_ completion: @escaping (PermissionStatus) -> Void) {
        if microphone {
            HostCameraCapture.requestMicrophoneAccess { completion(Self.status($0)) }
        } else {
            HostCameraCapture.requestAccess { completion(Self.status($0)) }
        }
    }
}

/// The camera module: the contract and its delegate.
public enum HostCameraModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [CameraCaptureProxy.descriptor, CameraCaptureDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        CameraCaptureProxy.register(HostCameraCapture.self, in: registrar)
        CameraCaptureDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.camera: CameraPermission(), .microphone: CameraPermission(microphone: true)]
    }
}
