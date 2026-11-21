import DynamicRuntime

/// One camera in the host: a live preview, photos, and video with sound
/// (`Documentation/Contracts/Camera.md`). App code uses `Camera` and
/// `CameraPreview`, which wrap this contract.
///
/// The pictures are the host's: no frame crosses to the guest. The host
/// shows the preview, writes a photo or a video to a file the guest names,
/// and reports through the delegate, which it calls on the main thread
/// whoever caused the change: the guest, the user on the preview, or the
/// system.
///
/// `.camera` asks the user. A video with sound also needs `.microphone`
/// in the manifest, and the user's leave for that.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | an `AVCaptureSession` |
/// | Android | CameraX |
/// | Linux | the camera portal, through a GStreamer pipeline |
/// | Browser | `getUserMedia` |
@DynamicRuntime("org.pureswift.camera.Capture", requires: .camera)
public protocol CameraCapture: AnyObject {

    /// A camera that's off. The host keeps `delegate` while it lives, and
    /// turns the camera off when the guest releases it.
    static func make(_ delegate: CameraCaptureDelegate) -> Self

    /// The cameras this device has. Bits: 1 back, 2 front, 4 external.
    static func positions() -> Int32

    /// A `CameraAccess` raw value. Never asks.
    static func access() -> Int32

    /// The microphone's `CameraAccess`. Never asks.
    static func microphoneAccess() -> Int32

    /// Asks the user if they haven't decided. Answered by
    /// `didChangeAccess`, once.
    static func requestAccess(_ delegate: CameraCaptureDelegate)

    static func requestMicrophoneAccess(_ delegate: CameraCaptureDelegate)

    /// What a `CameraPreview` node carries to say which camera it shows.
    func identifier() -> Int32

    /// Turns a camera on: a `CameraPosition` raw value. On one that's
    /// running, it switches. Answered by `didStart` or `didFail`.
    func start(_ position: Int32)

    func stop()

    /// Clamped to the camera's range, and answered by `didChangeZoom`.
    func setZoom(_ factor: Double)

    /// A `CameraFlashMode` raw value, for photos.
    func setFlashMode(_ mode: Int32)

    // A file as `Files` names it: a `FileDirectory` raw value and a path.

    /// Writes a JPEG, replacing what's there. Answered by
    /// `didCapturePhoto` or `didFailCapture`, with `request`.
    func capturePhoto(_ directory: Int32, path: String, request: Int32)

    /// Answered by `didStartRecording` or `didFailCapture`, with
    /// `request`.
    func startRecording(_ directory: Int32, path: String, audio: Bool, request: Int32)

    /// Answered by `didFinishRecording`, when the file is whole.
    func stopRecording()
}

/// What a camera does, from the host. Called on the main thread.
@DynamicCallback("org.pureswift.camera.CaptureDelegate")
public protocol CameraCaptureDelegate: AnyObject {

    /// A `CameraAccess` raw value. `microphone` says which was asked
    /// about.
    func didChangeAccess(_ access: Int32, microphone: Bool)

    /// A `CameraState` raw value.
    func didChangeState(_ state: Int32)

    /// The camera is on: which one, what it can zoom to, and whether it
    /// has a flash. Its zoom is 1.
    func didStart(_ position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool)

    /// The user pinched, or the guest set it.
    func didChangeZoom(_ factor: Double)

    /// Why the camera failed: a `CameraError` raw value.
    func didFail(_ error: Int32)

    /// The file is written. Sizes are the upright picture's pixels.
    func didCapturePhoto(_ request: Int32, width: Int32, height: Int32)

    /// Recording began at `timestamp`: nanoseconds on the `Clock.now()`
    /// timeline.
    func didStartRecording(_ request: Int32, timestamp: Int64)

    /// The file is whole. `duration` is seconds. `error` is 0, or the
    /// `CameraError` that cut the recording short.
    func didFinishRecording(_ request: Int32, duration: Double, mimeType: String, error: Int32)

    /// A photo wasn't taken, or a recording didn't begin.
    func didFailCapture(_ request: Int32, error: Int32)
}
