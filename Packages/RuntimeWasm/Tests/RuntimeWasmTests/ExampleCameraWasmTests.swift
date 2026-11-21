import Foundation
import Testing
import DynamicCamera
import DynamicFiles
import DynamicPhotos
import DynamicRuntime
import DynamicUI
import RuntimeABI
import RuntimeCamera
import RuntimeCore
import RuntimeHost
import RuntimeNative
import RuntimePhotos
import RuntimeWasm

/// A JPEG's start, with a frame that says its size.
private func jpeg(width: Int, height: Int) -> [UInt8] {
    let frame: [UInt8] = [0xFF, 0xC0, 0x00, 0x11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3]
    return [0xFF, 0xD8] + frame + [UInt8](repeating: 0, count: 12) + [0xFF, 0xD9]
}

/// A camera that does what it's asked at once: it comes on when started,
/// writes a photo when one is taken, and times a recording on the test's
/// clock.
final class WasmTestCameraEngine: CameraEngine {

    weak var camera: HostCameraCapture?

    let clock: ManualClock

    var calls: [String] = []

    /// The file being recorded to, and when it began.
    var recording: (path: String, began: Int64)?

    init(camera: HostCameraCapture, clock: ManualClock) {
        self.camera = camera
        self.clock = clock
    }

    func start(_ position: CameraPosition) {
        calls.append("start \(position)")
        // The back camera has three lenses and a flash; the front has one.
        camera?.started(minimumZoom: position == .back ? 0.5 : 1, maximumZoom: position == .back ? 8 : 4, hasFlash: position == .back)
    }

    func stop() {
        calls.append("stop")
        finish()
    }

    func setZoom(_ factor: Double) { calls.append("setZoom \(factor)") }
    func setFlashMode(_ mode: CameraFlashMode) { calls.append("setFlashMode \(mode)") }

    func capturePhoto(to path: String, completion: @escaping (Result<(width: Int, height: Int), CameraError>) -> Void) {
        calls.append("capturePhoto")
        do {
            try Data(jpeg(width: 4032, height: 3024)).write(to: URL(fileURLWithPath: path))
            completion(.success((4032, 3024)))
        } catch {
            completion(.failure(.writeFailed))
        }
    }

    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void) {
        calls.append("startRecording \(audio)")
        let header: [UInt8] = [0, 0, 0, 24] + Array("ftypisom".utf8) + [0, 0, 2, 0] + Array("isomiso2".utf8)
        do {
            try Data(header).write(to: URL(fileURLWithPath: path))
            recording = (path, clock.now())
            completion(nil)
        } catch {
            completion(.writeFailed)
        }
    }

    func stopRecording() {
        calls.append("stopRecording")
        finish()
    }

    /// The file is whole.
    private func finish() {
        guard let recording else { return }
        self.recording = nil
        camera?.recordingFinished(duration: Double(clock.now() - recording.began) / 1_000_000_000, mimeType: "video/mp4")
    }
}

/// A phone's two cameras, and a user who answers as the test says.
final class WasmTestCameras: CameraPlatform {

    let clock: ManualClock

    var positions: [CameraPosition] = [.back, .front]

    var access = CameraAccess.notDetermined

    var microphoneAccess = CameraAccess.notDetermined

    /// What the user answers about the microphone.
    var grantsMicrophone = CameraAccess.authorized

    var asked: [String] = []

    var engines: [WasmTestCameraEngine] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    func requestAccess(_ completion: @escaping (CameraAccess) -> Void) {
        asked.append("camera")
        access = .authorized
        completion(.authorized)
    }

    func requestMicrophoneAccess(_ completion: @escaping (CameraAccess) -> Void) {
        asked.append("microphone")
        microphoneAccess = grantsMicrophone
        completion(grantsMicrophone)
    }

    func makeEngine(for camera: HostCameraCapture) -> any CameraEngine {
        let engine = WasmTestCameraEngine(camera: camera, clock: clock)
        engines.append(engine)
        return engine
    }
}

/// The example camera app as App.wasm under WasmKit, with the shared host
/// implementations over a test's cameras, a photo library in memory and
/// real files in a temporary directory: the guest's `Camera`,
/// `CameraPreview` and `PhotoLibrary`, the `CameraCapture` and `Photos`
/// contracts, and `HostCameraCapture` and `HostPhotos`, end to end. Part
/// of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleCamera`; skipped without it.
    static var exampleCameraURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleCamera/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleCameraURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleCamera"))
    func exampleCameraInWasmMode() throws {
        let native = NativeRuntime.shared
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleCamera-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let clock = ManualClock(time: 1_000_000_000)
        native.runtime.clock = clock
        defer { native.runtime.clock = nil }
        // The hosts do their work at once, so each tap's files are there
        // when the tap returns.
        let caches = root.appendingPathComponent("Container/Caches")
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Container/Documents").path,
            .caches: caches.path,
            .temporary: root.appendingPathComponent("Container/tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let cameras = WasmTestCameras(clock: clock)
        HostCameraCapture.reset()
        HostCameraCapture.platform = cameras
        HostCameraCapture.allowsMicrophone = true
        HostCameraCapture.clock = clock
        HostCameraModule.register(in: native)
        defer { HostCameraCapture.reset() }
        // The user's photos, which this app only adds to.
        let store = MemoryPhotoStore(directory: root.appendingPathComponent("Originals").path)
        store.insert([0xFF, 0xD8, 0xFF], name: "IMG_0001.JPG", creationDate: 1000)
        var photoQuestions = 0
        HostPhotos.reset()
        HostPhotos.store = store
        HostPhotos.allowsReading = false
        HostPhotos.requester = { completion in
            photoQuestions += 1
            completion(.authorized)
        }
        HostPhotos.work = { $0() }
        HostPhotos.deliver = { $0() }
        HostPhotosModule.register(in: native)
        defer { HostPhotos.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleCameraURL))
        // The microphone is declared too; no contract requires it.
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.camera, .microphone, .photoLibrary])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.camera.Capture" }?.capability == .camera)
        #expect(contracts.first { $0.name == "org.pureswift.photos.Photos" }?.capability == .photoLibrary)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func taken(_ name: String) -> Bool {
            manager.fileExists(atPath: caches.appendingPathComponent(name).path)
        }

        // Nothing is on before the user is asked.
        #expect(text("status") == "Not asked" && text("camera") == "Back camera, off, x1.0")
        #expect(cameras.asked.isEmpty && !HostCameraCapture.isCameraOn)
        let preview = try #require(renderer.screen?.first { $0.type == "CameraPreview" })
        #expect(preview.props["scaling"] == "fill")
        guard case .int(let identifier)? = preview.props["camera"] else {
            Issue.record("the preview names no camera")
            return
        }
        let host = try #require(HostCameraCapture.camera(for: Int32(identifier)), "the camera the node names is the host's")
        let engine = try #require(cameras.engines.first)
        #expect(host.engine === engine && engine.calls.isEmpty)
        try tap("Shoot")
        #expect(text("status") == "The camera is off" && !taken("shot-1.jpg"))

        try tap("Allow")
        #expect(cameras.asked == ["camera"] && text("status") == "Ready")
        #expect(text("camera") == "Back camera, running, x1.0, flash" && HostCameraCapture.isCameraOn)
        #expect(engine.calls.first == "start back")

        // Zoom is clamped to what the camera can do.
        try tap("Zoom")
        #expect(text("camera") == "Back camera, running, x2.0, flash" && engine.calls.last == "setZoom 2.0")
        try tap("Zoom")
        try tap("Zoom")
        try tap("Zoom")
        #expect(text("camera") == "Back camera, running, x8.0, flash" && engine.calls.last == "setZoom 8.0")
        // A pinch on the preview is the host's, and the guest follows.
        host.zoomChanged(1.5)
        #expect(text("camera") == "Back camera, running, x1.5, flash")

        // A photo is a file of the app's own, then a copy in the user's photos.
        try tap("Shoot")
        #expect(taken("shot-2.jpg"), "where the app said")
        #expect(text("last") == "Photo 4032x3024" && text("status") == "Saved to Photos")
        #expect(photoQuestions == 1 && store.allAssets.count == 2)
        #expect(store.allAssets[0].kind == .image && store.allAssets[0].width == 4032 && store.allAssets[0].height == 3024)
        #expect(HostPhotos.effectiveAccess == .addOnly, "all it declared, whatever the user granted")

        try tap("Flip")
        #expect(text("camera") == "Front camera, running, x1.0" && engine.calls.last == "start front")

        // A video, with sound once the user allows the microphone.
        #expect(text("recording") == "Not recording")
        try tap("Record")
        #expect(cameras.asked == ["camera", "microphone"] && engine.calls.last == "startRecording true")
        #expect(text("status") == "Recording with sound" && text("recording") == "Recording 0s")
        #expect(renderer.screen?.button("Stop") != nil)
        clock.advance(by: 3_000_000_000)
        #expect(text("recording") == "Recording 3s", "once a second, on the guest's clock")
        try tap("Shoot")
        #expect(text("status") == "Busy", "no photos while recording")
        try tap("Stop")
        #expect(text("last") == "Video 3s video/mp4" && text("status") == "Saved to Photos")
        #expect(text("recording") == "Not recording" && renderer.screen?.button("Record") != nil)
        #expect(taken("clip-3.mp4") && store.allAssets.count == 3 && store.allAssets[0].kind == .video)
        #expect(photoQuestions == 1, "asked once")

        // The app leaves the front: the camera goes off, and a recording
        // ends with its file kept.
        try tap("Record")
        clock.advance(by: 2_000_000_000)
        HostCameraCapture.applicationDidEnterBackground()
        #expect(text("camera") == "Front camera, interrupted, x1.0" && !HostCameraCapture.isCameraOn)
        #expect(text("last") == "Video 2s video/mp4, cut short" && store.allAssets.count == 4)
        #expect(engine.calls.suffix(2) == ["stopRecording", "stop"])
        try tap("Shoot")
        #expect(text("status") == "Interrupted")
        HostCameraCapture.applicationWillEnterForeground()
        #expect(text("camera") == "Front camera, running, x1.0" && text("recording") == "Not recording")

        // Without the microphone the app records without sound: its choice.
        cameras.microphoneAccess = .denied
        try tap("Record")
        #expect(engine.calls.last == "startRecording false" && text("status") == "Recording without sound")
        #expect(cameras.asked.count == 2, "a decision isn't asked about again")
        try tap("Stop")
        #expect(store.allAssets.count == 5)

        // The user takes the photos back in the system's settings: the
        // capture is still the app's file.
        HostPhotos.access = .denied
        try tap("Shoot")
        #expect(text("last") == "Photo 4032x3024" && text("status") == "Not saved: no access to Photos")
        #expect(taken("shot-8.jpg") && store.allAssets.count == 5)
    }
}
