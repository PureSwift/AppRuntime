import Foundation
import Testing
import DynamicCamera
import DynamicFiles
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeCamera

/// A platform camera the test drives: it writes down what it's asked, and
/// reports when the test says.
final class TestCameraEngine: CameraEngine {

    weak var camera: HostCameraCapture?

    var calls: [String] = []

    var isOn = false

    /// The photos being taken, waiting for the test to finish them.
    var photos: [(path: String, completion: (Result<(width: Int, height: Int), CameraError>) -> Void)] = []

    /// The recordings asked for, waiting for the test to say they began.
    var starts: [(path: String, completion: (CameraError?) -> Void)] = []

    /// The file being recorded to.
    var recordingPath: String?

    init(camera: HostCameraCapture) {
        self.camera = camera
    }

    func start(_ position: CameraPosition) {
        calls.append("start \(position)")
        isOn = true
    }

    func stop() {
        calls.append("stop")
        isOn = false
    }

    func setZoom(_ factor: Double) { calls.append("setZoom \(factor)") }
    func setFlashMode(_ mode: CameraFlashMode) { calls.append("setFlashMode \(mode)") }

    func capturePhoto(to path: String, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void) {
        calls.append("capturePhoto")
        photos.append((path, completion))
    }

    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void) {
        calls.append("startRecording \(audio)")
        starts.append((path, completion))
    }

    func stopRecording() {
        calls.append("stopRecording")
    }

    // MARK: What the test makes happen

    /// The camera came on.
    func comeOn(zoom: ClosedRange<Double> = 0.5 ... 15, hasFlash: Bool = true) {
        camera?.started(minimumZoom: zoom.lowerBound, maximumZoom: zoom.upperBound, hasFlash: hasFlash)
    }

    /// Writes the photo being taken, and says so.
    func finishPhoto(width: Int = 4032, height: Int = 3024) throws {
        let photo = photos.removeFirst()
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: URL(fileURLWithPath: photo.path))
        photo.completion(.success((width, height)))
    }

    /// Recording began.
    func beginRecording() throws {
        let start = starts.removeFirst()
        try Data("video".utf8).write(to: URL(fileURLWithPath: start.path))
        recordingPath = start.path
        start.completion(nil)
    }

    /// The file is whole.
    func finishRecording(duration: Double, mimeType: String = "video/mp4", error: CameraError? = nil) {
        recordingPath = nil
        camera?.recordingFinished(duration: duration, mimeType: mimeType, error: error)
    }
}

/// A device's cameras, with a user the test answers for.
final class TestCameraPlatform: CameraPlatform {

    var positions: [CameraPosition] = [.back, .front]

    var access = CameraAccess.authorized

    var microphoneAccess = CameraAccess.authorized

    /// What the user answers when asked.
    var grants = CameraAccess.authorized

    var asked: [String] = []

    var engines: [TestCameraEngine] = []

    func requestAccess(_ completion: @escaping (CameraAccess) -> Void) {
        asked.append("camera")
        access = grants
        completion(grants)
        // A platform that answers twice is heard once.
        completion(.denied)
    }

    func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void) {
        asked.append("microphone")
        microphoneAccess = grants
        completion(grants)
    }

    func makeEngine(for camera: HostCameraCapture) -> any CameraEngine {
        let engine = TestCameraEngine(camera: camera)
        engines.append(engine)
        return engine
    }
}

/// `HostCameraCapture` over a test's cameras and real files, driven from
/// the guest's `Camera` through the runtime.
///
/// Serialized: `HostCameraCapture`, `HostFiles`, the native runtime and its
/// clock are shared.
@Suite(.serialized) final class RuntimeCameraTests {

    let root: URL

    let platform = TestCameraPlatform()

    let clock = ManualClock(time: 5_000_000_000)

    let files = DynamicFiles.FileManager()

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeCameraTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let container = root.appendingPathComponent("Container")
        let native = NativeRuntime.shared
        native.capabilities = nil
        native.runtime.clock = clock
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .caches: container.appendingPathComponent("Caches").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostCameraCapture.reset()
        HostCameraCapture.platform = platform
        HostCameraCapture.allowsMicrophone = true
        HostCameraCapture.clock = clock
        HostCameraModule.register(in: native)
    }

    deinit {
        HostCameraCapture.reset()
        NativeRuntime.shared.runtime.clock = nil
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    func failure<Value>(_ result: Result<Value, CameraError>?) -> CameraError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    /// A camera that's running, and the platform's engine behind it.
    func running(_ position: CameraPosition = .back) throws -> (Camera, TestCameraEngine) {
        let camera = Camera()
        camera.start(position)
        let engine = try #require(platform.engines.last)
        engine.comeOn()
        #expect(camera.state == .running)
        return (camera, engine)
    }

    func photo(_ camera: Camera, to file: FilePath) -> Result<CapturedPhoto, CameraError>? {
        var result: Result<CapturedPhoto, CameraError>?
        camera.capturePhoto(to: file) { result = $0 }
        return result
    }

    func onDisk(_ file: FilePath) -> [UInt8]? {
        guard let path = try? HostFiles.path(of: file.directory.rawValue, path: file.path) else { return nil }
        return Foundation.FileManager.default.contents(atPath: path).map { [UInt8]($0) }
    }

    /// Starts a recording that has begun.
    func record(_ camera: Camera, _ engine: TestCameraEngine, to file: FilePath, audio: Bool = false) throws {
        var began: Result<Void, CameraError>?
        camera.startRecording(to: file, audio: audio) { began = $0 }
        try engine.beginRecording()
        #expect(failure(began) == nil && camera.isRecording)
    }

    // MARK: The module

    @Test func moduleListsItsContracts() {
        #expect(HostCameraModule.contracts.map(\.name) == ["org.pureswift.camera.Capture", "org.pureswift.camera.CaptureDelegate"])
        let providers = HostCameraModule.permissionProviders()
        #expect(providers[.camera]?.status() == .granted && providers[.microphone]?.status() == .granted)
        platform.access = .notDetermined
        platform.microphoneAccess = .denied
        #expect(providers[.camera]?.status() == .notDetermined && providers[.microphone]?.status() == .denied)
        var granted: PermissionStatus?
        providers[.camera]?.request { granted = $0 }
        #expect(granted == .granted && platform.asked == ["camera"])
        HostCameraCapture.platform = nil
        #expect(providers[.camera]?.status() == .unavailable && providers[.microphone]?.status() == .unavailable)
    }

    // MARK: The device and the user's leave

    @Test func withoutAPlatformThereIsNoCamera() {
        HostCameraCapture.platform = nil
        #expect(Camera.positions.isEmpty)
        #expect(Camera.access == .unavailable && Camera.microphoneAccess == .unavailable)
        var granted: CameraAccess?
        Camera.requestAccess { granted = $0 }
        #expect(granted == .unavailable)
        let camera = Camera()
        camera.start()
        #expect(camera.state == .failed && camera.error == .unavailable)
        #expect(failure(photo(camera, to: .caches / "shot.jpg")) == .notRunning)
    }

    @Test func theDeviceSaysWhichCamerasItHas() {
        #expect(Camera.positions == [.back, .front])
        platform.positions = [.external]
        #expect(Camera.positions == [.external])
        let camera = Camera()
        camera.start(.back)
        #expect(camera.state == .failed && camera.error == .unavailable, "no such camera on this device")
        #expect(platform.engines.last?.calls.isEmpty == true)
    }

    @Test func theUserIsAskedOnceForEach() {
        platform.access = .notDetermined
        platform.microphoneAccess = .notDetermined
        #expect(Camera.access == .notDetermined && platform.asked.isEmpty, "reading the access never asks")
        var granted: [CameraAccess] = []
        Camera.requestAccess { granted.append($0) }
        Camera.requestAccess { granted.append($0) }
        #expect(granted == [.authorized, .authorized] && platform.asked == ["camera"])

        platform.grants = .denied
        Camera.requestMicrophoneAccess { granted.append($0) }
        Camera.requestMicrophoneAccess { granted.append($0) }
        #expect(granted.suffix(2) == [.denied, .denied] && platform.asked == ["camera", "microphone"])
        #expect(Camera.access == .authorized && Camera.microphoneAccess == .denied)
    }

    @Test func aMicrophoneNeedsTheManifestsLeave() {
        HostCameraCapture.allowsMicrophone = false
        platform.microphoneAccess = .notDetermined
        #expect(Camera.microphoneAccess == .denied)
        var granted: CameraAccess?
        Camera.requestMicrophoneAccess { granted = $0 }
        #expect(granted == .denied && platform.asked.isEmpty, "the user isn't asked for what the app didn't declare")
    }

    // MARK: Running

    @Test func startingNeedsTheUsersLeave() {
        platform.access = .notDetermined
        let camera = Camera()
        camera.start()
        #expect(camera.state == .failed && camera.error == .notAuthorized)
        #expect(platform.asked.isEmpty, "starting doesn't ask")
        #expect(!HostCameraCapture.isCameraOn)

        platform.access = .authorized
        camera.start()
        #expect(camera.state == .starting && camera.error == nil)
        let engine = platform.engines[0]
        #expect(engine.calls == ["start back"])
        engine.comeOn(zoom: 1 ... 8, hasFlash: false)
        #expect(camera.state == .running && camera.zoomRange == 1 ... 8 && !camera.hasFlash)
        #expect(HostCameraCapture.isCameraOn)
        camera.stop()
        #expect(camera.state == .stopped && engine.calls.last == "stop" && !HostCameraCapture.isCameraOn)
        camera.stop()
        #expect(engine.calls.filter { $0 == "stop" }.count == 1)
    }

    @Test func startingAgainSwitches() throws {
        let (camera, engine) = try running()
        camera.start(.back)
        #expect(engine.calls == ["start back", "setFlashMode off"], "the camera that's on is on")
        camera.zoomFactor = 3
        #expect(camera.zoomFactor == 3)
        camera.start(.front)
        #expect(engine.calls.last == "start front" && camera.state == .starting, "until the other camera is on")
        engine.comeOn(zoom: 1 ... 4, hasFlash: false)
        #expect(camera.position == .front && camera.zoomRange == 1 ... 4 && camera.zoomFactor == 1 && !camera.hasFlash)

        // One that isn't there turns off what was.
        camera.start(.external)
        #expect(camera.state == .failed && camera.error == .unavailable)
        #expect(engine.calls.last == "stop" && !engine.isOn)
    }

    @Test func oneCameraIsOnAtATime() throws {
        let (first, firstEngine) = try running()
        let second = Camera()
        second.start(.front)
        #expect(first.state == .stopped && firstEngine.calls.last == "stop")
        let secondEngine = platform.engines[1]
        secondEngine.comeOn()
        #expect(second.state == .running)
        #expect(HostCameraCapture.camera(for: second.identifier)?.engine === secondEngine)
        #expect(HostCameraCapture.camera(for: first.identifier)?.engine === firstEngine)
        #expect(HostCameraCapture.camera(for: 999) == nil)
    }

    @Test func anEngineThatFailsSaysWhy() throws {
        let camera = Camera()
        camera.start()
        let engine = platform.engines[0]
        HostCameraCapture.camera(for: camera.identifier)?.failed(.busy)
        #expect(camera.state == .failed && camera.error == .busy, "another app has the camera")
        engine.comeOn()
        #expect(camera.state == .failed, "a camera that failed doesn't come on behind it")

        camera.start()
        engine.comeOn()
        #expect(camera.state == .running && camera.error == nil)
    }

    @Test func releasingTheCameraTurnsItOff() throws {
        var camera: Camera? = try running().0
        let engine = platform.engines[0]
        let identifier = try #require(camera?.identifier)
        try record(try #require(camera), engine, to: .caches / "clip.mp4")
        camera = nil
        #expect(engine.calls.suffix(2) == ["stopRecording", "stop"], "a recording ends first, and its file is kept")
        #expect(HostCameraCapture.camera(for: identifier) == nil)
        #expect(onDisk(.caches / "clip.mp4") != nil)
    }

    // MARK: Zoom and flash

    @Test func zoomIsClampedToTheCamerasRange() throws {
        let (camera, engine) = try running()
        camera.zoomFactor = 2
        #expect(engine.calls.last == "setZoom 2.0" && camera.zoomFactor == 2)
        camera.zoomFactor = 99
        #expect(engine.calls.last == "setZoom 15.0" && camera.zoomFactor == 15)
        camera.zoomFactor = 0.1
        #expect(engine.calls.last == "setZoom 0.5" && camera.zoomFactor == 0.5)

        // A pinch on the preview.
        let host = try #require(HostCameraCapture.camera(for: camera.identifier))
        host.zoomChanged(4.25)
        #expect(camera.zoomFactor == 4.25)
        host.zoomChanged(40)
        #expect(camera.zoomFactor == 15)
        camera.stop()
        host.zoomChanged(2)
        #expect(camera.zoomFactor == 15, "a camera that's off isn't zoomed")
    }

    @Test func theFlashIsSetWhereThereIsOne() throws {
        let camera = Camera()
        camera.flashMode = .auto
        camera.start()
        let engine = platform.engines[0]
        #expect(!engine.calls.contains { $0.hasPrefix("setFlashMode") }, "nothing is on to set")
        engine.comeOn()
        #expect(engine.calls.last == "setFlashMode auto", "what was asked for before it came on")
        camera.flashMode = .on
        #expect(engine.calls.last == "setFlashMode on")

        camera.start(.front)
        engine.comeOn(hasFlash: false)
        let asked = engine.calls.count
        camera.flashMode = .off
        #expect(engine.calls.count == asked, "a camera with no flash isn't told")
    }

    // MARK: Photos

    @Test func aPhotoIsWrittenWhereTheAppSays() throws {
        let (camera, engine) = try running()
        var result: Result<CapturedPhoto, CameraError>?
        camera.capturePhoto(to: .caches / "shots" / "one.jpg") { result = $0 }
        #expect(result == nil && engine.calls.last == "capturePhoto")
        let expected = root.appendingPathComponent("Container/Caches/shots/one.jpg").path
        #expect(engine.photos[0].path == expected, "an absolute path, found as `Files` finds it")
        try engine.finishPhoto(width: 3024, height: 4032)
        #expect(try #require(result).get() == CapturedPhoto(path: .caches / "shots" / "one.jpg", width: 3024, height: 4032))
        #expect(onDisk(.caches / "shots" / "one.jpg") == [0xFF, 0xD8, 0xFF, 0xD9])

        // The guest reads it as any of its files.
        var read: Result<[UInt8], FileError>?
        files.contents(at: .caches / "shots" / "one.jpg") { read = $0 }
        #expect(read == .success([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    @Test func onePhotoAtATime() throws {
        let (camera, engine) = try running()
        var first: Result<CapturedPhoto, CameraError>?
        camera.capturePhoto(to: .caches / "a.jpg") { first = $0 }
        #expect(failure(photo(camera, to: .caches / "b.jpg")) == .busy)
        #expect(engine.photos.count == 1, "the second never reached the camera")
        try engine.finishPhoto()
        #expect(failure(first) == nil && first != nil)

        camera.capturePhoto(to: .caches / "b.jpg") { first = $0 }
        let completion = engine.photos[0].completion
        try engine.finishPhoto(width: 10, height: 10)
        completion(.failure(.unknown))
        #expect(try #require(first).get().width == 10, "an engine that answers twice is heard once")

        camera.capturePhoto(to: .caches / "c.jpg") { first = $0 }
        engine.photos.removeFirst().completion(.failure(.writeFailed))
        #expect(failure(first) == .writeFailed, "no space")
    }

    @Test func aPhotoNeedsACameraThatsOnAndAPlaceToWrite() throws {
        let camera = Camera()
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .notRunning)
        camera.start()
        let engine = platform.engines[0]
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .notRunning, "still starting")
        engine.comeOn()

        #expect(failure(photo(camera, to: .bundle / "a.jpg")) == .writeFailed, "not a place the app may write")
        #expect(failure(photo(camera, to: FilePath(FileDirectory(rawValue: 700)) / "a.jpg")) == .writeFailed)
        #expect(failure(photo(camera, to: .caches / ".." / "a.jpg")) == .writeFailed)
        try Foundation.FileManager.default.createDirectory(at: root.appendingPathComponent("Container/Caches/folder"), withIntermediateDirectories: true)
        #expect(failure(photo(camera, to: .caches / "folder")) == .writeFailed, "a folder is there")
        try Data("x".utf8).write(to: root.appendingPathComponent("Container/Caches/file"))
        #expect(failure(photo(camera, to: .caches / "file" / "a.jpg")) == .writeFailed, "a file is where its folder would be")
        #expect(engine.photos.isEmpty)

        camera.stop()
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .notRunning)
    }

    @Test func aPhotoBeingTakenWhenTheCameraGoesOffIsnt() throws {
        let (camera, engine) = try running()
        var result: Result<CapturedPhoto, CameraError>?
        camera.capturePhoto(to: .caches / "a.jpg") { result = $0 }
        camera.stop()
        #expect(failure(result) == .interrupted)
        let late = engine.photos.removeFirst().completion
        result = nil
        late(.success((1, 1)))
        #expect(result == nil, "answered once")
    }

    // MARK: Video

    @Test func aRecordingBeginsOnTheGuestsClock() throws {
        let (camera, engine) = try running()
        var began: Result<Void, CameraError>?
        camera.startRecording(to: .caches / "clip.mp4", audio: true) { began = $0 }
        #expect(engine.calls.last == "startRecording true" && began == nil && !camera.isRecording)
        #expect(engine.starts[0].path == root.appendingPathComponent("Container/Caches/clip.mp4").path)
        clock.advance(by: 300_000_000)
        try engine.beginRecording()
        #expect(failure(began) == nil && began != nil && camera.isRecording)
        clock.advance(by: 4_000_000_000)
        #expect(camera.recordingDuration == 4, "from when the host says it began, which is the guest's clock's")

        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        var stopped: Result<CapturedVideo, CameraError>?
        camera.stopRecording { stopped = $0 }
        #expect(engine.calls.last == "stopRecording" && stopped == nil && camera.isRecording, "until the file is whole")
        engine.finishRecording(duration: 4.1)
        let video = CapturedVideo(path: .caches / "clip.mp4", duration: 4.1, contentType: "video/mp4")
        #expect(try #require(stopped).get() == video && finished == [video])
        #expect(!camera.isRecording && camera.state == .running)
        engine.finishRecording(duration: 9)
        #expect(finished.count == 1, "a finish nobody is waiting for is nothing")
    }

    @Test func soundNeedsTheCapabilityAndTheUsersLeave() throws {
        let (camera, engine) = try running()
        var began: Result<Void, CameraError>?
        HostCameraCapture.allowsMicrophone = false
        camera.startRecording(to: .caches / "clip.mp4", audio: true) { began = $0 }
        #expect(failure(began) == .notAuthorized)
        HostCameraCapture.allowsMicrophone = true
        platform.microphoneAccess = .denied
        camera.startRecording(to: .caches / "clip.mp4", audio: true) { began = $0 }
        #expect(failure(began) == .notAuthorized)
        platform.microphoneAccess = .notDetermined
        camera.startRecording(to: .caches / "clip.mp4", audio: true) { began = $0 }
        #expect(failure(began) == .notAuthorized && platform.asked.isEmpty, "recording doesn't ask")
        #expect(engine.starts.isEmpty, "a silent video isn't recorded instead")
        #expect(onDisk(.caches / "clip.mp4") == nil)

        // Without sound, none of it is needed.
        try record(camera, engine, to: .caches / "silent.mp4", audio: false)
        #expect(engine.calls.last == "startRecording false")
    }

    @Test func oneRecordingAndNoPhotosMeanwhile() throws {
        let (camera, engine) = try running()
        var began: Result<Void, CameraError>?
        camera.startRecording(to: .caches / "a.mp4", audio: false) { began = $0 }
        var second: Result<Void, CameraError>?
        camera.startRecording(to: .caches / "b.mp4", audio: false) { second = $0 }
        #expect(failure(second) == .busy, "one is already beginning")
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .busy)
        try engine.beginRecording()
        #expect(failure(began) == nil)
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .busy, "no photos while recording")
        camera.startRecording(to: .caches / "b.mp4", audio: false) { second = $0 }
        #expect(failure(second) == .busy && engine.starts.isEmpty)

        camera.stopRecording { _ in }
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .busy, "nor until the file is whole")
        engine.finishRecording(duration: 1)
        camera.capturePhoto(to: .caches / "a.jpg") { _ in }
        #expect(engine.photos.count == 1)
    }

    @Test func aRecordingThatCantBeginSaysWhy() throws {
        let (camera, engine) = try running()
        var began: Result<Void, CameraError>?
        camera.startRecording(to: .bundle / "clip.mp4", audio: false) { began = $0 }
        #expect(failure(began) == .writeFailed && engine.starts.isEmpty)
        camera.startRecording(to: .caches / "clip.mp4", audio: false) { began = $0 }
        engine.starts.removeFirst().completion(.writeFailed)
        #expect(failure(began) == .writeFailed && !camera.isRecording)
        try record(camera, engine, to: .caches / "clip.mp4")

        let off = Camera()
        off.startRecording(to: .caches / "x.mp4", audio: false) { began = $0 }
        #expect(failure(began) == .notRunning)
    }

    @Test func stoppingTheCameraEndsARecordingWithItsFile() throws {
        let (camera, engine) = try running()
        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        try record(camera, engine, to: .caches / "clip.mp4")
        camera.stop()
        #expect(engine.calls.suffix(2) == ["stopRecording", "stop"])
        #expect(camera.state == .stopped && camera.isRecording, "until the file is whole")
        engine.finishRecording(duration: 2)
        #expect(finished.map(\.interruption) == [nil], "the app stopped it: nothing cut it short")
        #expect(!camera.isRecording && onDisk(.caches / "clip.mp4") != nil)

        // The disk filled: the engine ended it itself.
        camera.start()
        engine.comeOn()
        try record(camera, engine, to: .caches / "long.mp4")
        engine.finishRecording(duration: 60, error: .writeFailed)
        #expect(finished.last == CapturedVideo(path: .caches / "long.mp4", duration: 60, contentType: "video/mp4", interruption: .writeFailed))
        #expect(camera.state == .running)
    }

    @Test func switchingCamerasEndsARecording() throws {
        let (camera, engine) = try running()
        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        try record(camera, engine, to: .caches / "clip.mp4")
        camera.start(.front)
        #expect(engine.calls.suffix(2) == ["stopRecording", "start front"])
        engine.finishRecording(duration: 3)
        #expect(finished.map(\.interruption) == [.interrupted])
    }

    // MARK: The background and interruptions

    @Test func theCameraIsOffWhileTheAppIsntInFront() throws {
        let (camera, engine) = try running(.front)
        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        try record(camera, engine, to: .caches / "clip.mp4")

        HostCameraCapture.applicationDidEnterBackground()
        #expect(engine.calls.suffix(2) == ["stopRecording", "stop"], "it ends a recording first")
        #expect(camera.state == .interrupted && !HostCameraCapture.isCameraOn)
        engine.finishRecording(duration: 7)
        #expect(finished == [CapturedVideo(path: .caches / "clip.mp4", duration: 7, contentType: "video/mp4", interruption: .interrupted)])
        #expect(failure(photo(camera, to: .caches / "a.jpg")) == .interrupted)
        HostCameraCapture.applicationDidEnterBackground()
        #expect(engine.calls.filter { $0 == "stop" }.count == 1)

        HostCameraCapture.applicationWillEnterForeground()
        #expect(engine.calls.last == "start front" && camera.state == .interrupted, "until the camera is back")
        engine.comeOn(zoom: 1 ... 4, hasFlash: false)
        #expect(camera.state == .running && camera.zoomRange == 1 ... 4)
        #expect(!camera.isRecording, "a recording doesn't begin again by itself")
    }

    @Test func aCameraStartedInTheBackgroundWaits() throws {
        HostCameraCapture.applicationDidEnterBackground()
        let camera = Camera()
        camera.start()
        let engine = platform.engines[0]
        #expect(camera.state == .interrupted && engine.calls.isEmpty)
        HostCameraCapture.applicationWillEnterForeground()
        #expect(engine.calls == ["start back"])
        engine.comeOn()
        #expect(camera.state == .running)

        // One that came on as the app left goes off again.
        camera.start(.front)
        HostCameraCapture.applicationDidEnterBackground()
        #expect(camera.state == .interrupted)
        engine.comeOn()
        #expect(camera.state == .interrupted && engine.calls.last == "stop")

        // Stopped in the background, it stays off.
        camera.stop()
        HostCameraCapture.applicationWillEnterForeground()
        #expect(camera.state == .stopped && engine.calls.last == "stop")
    }

    @Test func theSystemTakesTheCameraAndGivesItBack() throws {
        let (camera, engine) = try running()
        let host = try #require(HostCameraCapture.camera(for: camera.identifier))
        var taken: Result<CapturedPhoto, CameraError>?
        camera.capturePhoto(to: .caches / "a.jpg") { taken = $0 }
        host.interruptionBegan()
        host.interruptionBegan()
        #expect(camera.state == .interrupted && failure(taken) == .interrupted)
        #expect(!engine.calls.contains("stop"), "the engine stopped by itself")

        // Back in front isn't enough while the call goes on.
        HostCameraCapture.applicationDidEnterBackground()
        HostCameraCapture.applicationWillEnterForeground()
        #expect(engine.calls.filter { $0.hasPrefix("start") }.count == 1)
        host.interruptionEnded()
        #expect(engine.calls.last == "start back")
        engine.comeOn()
        #expect(camera.state == .running)
        host.interruptionEnded()
        #expect(engine.calls.filter { $0.hasPrefix("start") }.count == 2)
    }
}
