import Testing
import DynamicCamera
import DynamicFiles
import DynamicRuntime
import DynamicSwiftUI
import DynamicUI
import RuntimeCore
import RuntimeNative

/// A host's camera that only writes down what it's asked, and keeps its
/// delegate for the test to call.
final class ScriptedCapture: CameraCapture {

    nonisolated(unsafe) static var all: [Unowned] = []

    nonisolated(unsafe) static var destroyed: [Int32] = []

    nonisolated(unsafe) static var cameras: Int32 = 3

    nonisolated(unsafe) static var level: Int32 = 0

    nonisolated(unsafe) static var microphoneLevel: Int32 = 0

    /// The delegates of the questions put to the user, in order.
    nonisolated(unsafe) static var questions: [(microphone: Bool, delegate: any CameraCaptureDelegate)] = []

    struct Unowned {
        weak var capture: ScriptedCapture?
    }

    static var last: ScriptedCapture? { all.last?.capture }

    let delegate: any CameraCaptureDelegate

    let id: Int32

    var calls: [String] = []

    init(delegate: any CameraCaptureDelegate) {
        self.delegate = delegate
        self.id = Int32(Self.all.count + 1)
    }

    deinit {
        Self.destroyed.append(id)
    }

    static func make(_ delegate: any CameraCaptureDelegate) -> ScriptedCapture {
        let capture = ScriptedCapture(delegate: delegate)
        all.append(Unowned(capture: capture))
        return capture
    }

    static func positions() -> Int32 { cameras }
    static func access() -> Int32 { level }
    static func microphoneAccess() -> Int32 { microphoneLevel }

    static func requestAccess(_ delegate: any CameraCaptureDelegate) {
        questions.append((false, delegate))
    }

    static func requestMicrophoneAccess(_ delegate: any CameraCaptureDelegate) {
        questions.append((true, delegate))
    }

    func identifier() -> Int32 { id }
    func start(_ position: Int32) { calls.append("start \(position)") }
    func stop() { calls.append("stop") }
    func setZoom(_ factor: Double) { calls.append("setZoom \(factor)") }
    func setFlashMode(_ mode: Int32) { calls.append("setFlashMode \(mode)") }

    func capturePhoto(_ directory: Int32, path: String, request: Int32) {
        calls.append("capturePhoto \(directory) \(path) #\(request)")
    }

    func startRecording(_ directory: Int32, path: String, audio: Bool, request: Int32) {
        calls.append("startRecording \(directory) \(path) \(audio) #\(request)")
    }

    func stopRecording() { calls.append("stopRecording") }
}

/// Records what a view graph sends.
final class CameraSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }
}

struct Viewfinder: View {

    let camera: Camera

    var body: some View {
        VStack {
            CameraPreview(camera, scaling: .fit)
            Text(camera.isRecording ? "Recording \(Int(camera.recordingDuration))" : "Ready")
            Text("x\(Int(camera.zoomFactor))")
        }
    }
}

/// Serialized: the tests share the native runtime, its clock and the
/// scripted host's cameras.
@Suite(.serialized) final class DynamicCameraTests {

    let clock = ManualClock(time: 1_000_000_000)

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        native.runtime.clock = clock
        CameraCaptureProxy.register(ScriptedCapture.self, in: native)
        CameraCaptureDelegateProxy.registerInterface(in: native)
        ScriptedCapture.all = []
        ScriptedCapture.destroyed = []
        ScriptedCapture.cameras = 3
        ScriptedCapture.level = 0
        ScriptedCapture.microphoneLevel = 0
        ScriptedCapture.questions = []
    }

    deinit {
        NativeRuntime.shared.runtime.clock = nil
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, CameraError>?) -> CameraError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    /// A camera that's running, and its host.
    func running(_ position: CameraPosition = .back) throws -> (Camera, ScriptedCapture) {
        let camera = Camera()
        camera.start(position)
        let host = try #require(ScriptedCapture.last)
        host.delegate.didChangeState(CameraState.starting.rawValue)
        host.delegate.didStart(position.rawValue, minimumZoom: 0.5, maximumZoom: 15, hasFlash: position == .back)
        host.delegate.didChangeState(CameraState.running.rawValue)
        return (camera, host)
    }

    // MARK: Contracts

    @Test func theCameraRequiresTheCamera() {
        let capture = CameraCaptureProxy.descriptor
        #expect(capture.name == "org.pureswift.camera.Capture")
        #expect(capture.capability == .camera, "the microphone is asked for apart, and only for sound")
        #expect(method(capture, "make:")?.kind == .constructor)
        #expect(method(capture, "positions")?.signature == Signature("()I"))
        #expect(method(capture, "positions")?.kind == .static)
        #expect(method(capture, "requestMicrophoneAccess:")?.signature == Signature("(O)V"))
        #expect(method(capture, "start:")?.signature == Signature("(I)V"))
        #expect(method(capture, "setZoom:")?.signature == Signature("(D)V"))
        #expect(method(capture, "capturePhoto:path:request:")?.signature == Signature("(IOI)V"))
        #expect(method(capture, "startRecording:path:audio:request:")?.signature == Signature("(IOZI)V"))
        #expect(capture.methods.count == 14)

        let delegate = CameraCaptureDelegateProxy.descriptor
        #expect(delegate.name == "org.pureswift.camera.CaptureDelegate" && delegate.kind == .callback)
        #expect(method(delegate, "didChangeAccess:microphone:")?.signature == Signature("(IZ)V"))
        #expect(method(delegate, "didStart:minimumZoom:maximumZoom:hasFlash:")?.signature == Signature("(IDDZ)V"))
        #expect(method(delegate, "didStartRecording:timestamp:")?.signature == Signature("(IJ)V"))
        #expect(method(delegate, "didFinishRecording:duration:mimeType:error:")?.signature == Signature("(IDOI)V"))
        #expect(delegate.methods.count == 9)

        let descriptors = [capture, delegate]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: The device and the user's leave

    @Test func theDeviceSaysWhichCamerasItHas() {
        #expect(Camera.positions == [.back, .front])
        ScriptedCapture.cameras = 4
        #expect(Camera.positions == [.external])
        ScriptedCapture.cameras = 7 | 64
        #expect(Camera.positions == [.back, .front, .external], "a camera from a newer host isn't one to name")
        ScriptedCapture.cameras = 0
        #expect(Camera.positions.isEmpty)
        #expect(ScriptedCapture.all.isEmpty, "asking makes no camera")
    }

    @Test func accessIsReadAndNeverAsks() {
        ScriptedCapture.level = CameraAccess.authorized.rawValue
        ScriptedCapture.microphoneLevel = CameraAccess.restricted.rawValue
        #expect(Camera.access == .authorized && Camera.microphoneAccess == .restricted)
        ScriptedCapture.level = 77
        ScriptedCapture.microphoneLevel = 4
        #expect(Camera.access == .denied && Camera.microphoneAccess == .denied, "an access from a newer host isn't one to rely on")
        #expect(ScriptedCapture.questions.isEmpty)
    }

    @Test func askingGivesWhatTheUserGranted() {
        var granted: [String] = []
        Camera.requestAccess { granted.append("camera \($0)") }
        Camera.requestMicrophoneAccess { granted.append("microphone \($0)") }
        #expect(ScriptedCapture.questions.map(\.microphone) == [false, true] && granted.isEmpty)

        // An answer to the other question isn't this one's.
        ScriptedCapture.questions[0].delegate.didChangeAccess(CameraAccess.denied.rawValue, microphone: true)
        #expect(granted.isEmpty)
        ScriptedCapture.questions[0].delegate.didChangeAccess(CameraAccess.authorized.rawValue, microphone: false)
        ScriptedCapture.questions[0].delegate.didChangeAccess(CameraAccess.denied.rawValue, microphone: false)
        #expect(granted == ["camera authorized"], "only a host's first answer counts")
        ScriptedCapture.questions[1].delegate.didChangeAccess(123, microphone: true)
        #expect(granted == ["camera authorized", "microphone denied"])
    }

    // MARK: Running

    @Test func aCameraIsOffUntilItsStarted() {
        let camera = Camera()
        #expect(camera.state == .stopped && camera.position == .back && camera.error == nil)
        #expect(camera.zoomFactor == 1 && camera.zoomRange == 1 ... 1 && !camera.hasFlash && camera.flashMode == .off)
        #expect(!camera.isRecording && camera.recordingDuration == 0)
        camera.stop()
        #expect(ScriptedCapture.all.isEmpty, "nothing made means nothing to turn off")
    }

    @Test func startingReportsWhatTheCameraCanDo() throws {
        let camera = Camera()
        camera.start(.front)
        let host = try #require(ScriptedCapture.last)
        #expect(host.calls == ["start 2"])
        host.delegate.didChangeState(CameraState.starting.rawValue)
        #expect(camera.state == .starting)
        host.delegate.didStart(2, minimumZoom: 1, maximumZoom: 4, hasFlash: false)
        host.delegate.didChangeState(CameraState.running.rawValue)
        #expect(camera.state == .running && camera.position == .front)
        #expect(camera.zoomRange == 1 ... 4 && !camera.hasFlash)

        // Starting again switches.
        camera.start()
        #expect(host.calls.last == "start 1")
        host.delegate.didStart(1, minimumZoom: 0.5, maximumZoom: 15, hasFlash: true)
        #expect(camera.position == .back && camera.zoomRange == 0.5 ... 15 && camera.hasFlash)

        camera.stop()
        #expect(host.calls.last == "stop")
        host.delegate.didChangeState(CameraState.stopped.rawValue)
        #expect(camera.state == .stopped)
        #expect(ScriptedCapture.all.count == 1, "one host camera for one `Camera`")
    }

    @Test func aFailureSaysWhy() throws {
        let camera = Camera()
        camera.start()
        let host = try #require(ScriptedCapture.last)
        host.delegate.didChangeState(CameraState.failed.rawValue)
        host.delegate.didFail(CameraError.notAuthorized.rawValue)
        #expect(camera.state == .failed && camera.error == .notAuthorized)
        host.delegate.didFail(999)
        #expect(camera.error == .unknown)

        // The next start clears it.
        host.delegate.didChangeState(CameraState.starting.rawValue)
        #expect(camera.state == .starting && camera.error == nil)
        host.delegate.didChangeState(42)
        #expect(camera.state == .starting, "a state from a newer host changes nothing here")
        host.delegate.didChangeState(CameraState.interrupted.rawValue)
        #expect(camera.state == .interrupted)
    }

    @Test func whatAHostSaysBadlyOfItsZoomIsNoZoom() throws {
        let (camera, host) = try running()
        #expect(camera.zoomRange == 0.5 ... 15)
        for (low, high) in [(4.0, 1.0), (0.0, 3.0), (-1.0, 3.0), (Double.nan, 3.0), (1.0, Double.infinity)] {
            host.delegate.didStart(1, minimumZoom: low, maximumZoom: high, hasFlash: true)
            #expect(camera.zoomRange == 1 ... 1, "\(low) to \(high)")
            host.delegate.didStart(1, minimumZoom: 0.5, maximumZoom: 15, hasFlash: true)
        }
        host.delegate.didStart(9, minimumZoom: 1, maximumZoom: 2, hasFlash: true)
        #expect(camera.position == .back, "a position from a newer host leaves the last one")
    }

    // MARK: Zoom and flash

    @Test func zoomIsTheHostsToClamp() throws {
        let (camera, host) = try running()
        camera.zoomFactor = 2
        #expect(host.calls.last == "setZoom 2.0")
        #expect(camera.zoomFactor == 1, "it's what the host says it became")
        host.delegate.didChangeZoom(2)
        #expect(camera.zoomFactor == 2)
        camera.zoomFactor = 99
        host.delegate.didChangeZoom(15)
        #expect(camera.zoomFactor == 15)
        // A pinch on the preview.
        host.delegate.didChangeZoom(3.5)
        #expect(camera.zoomFactor == 3.5)
        host.delegate.didChangeZoom(.nan)
        #expect(camera.zoomFactor == 3.5)

        let asked = host.calls.count
        camera.zoomFactor = .infinity
        #expect(host.calls.count == asked)
        // A switch of camera starts again at the main lens.
        host.delegate.didStart(2, minimumZoom: 1, maximumZoom: 4, hasFlash: false)
        #expect(camera.zoomFactor == 1)

        let off = Camera()
        off.zoomFactor = 3
        #expect(off.zoomFactor == 1 && ScriptedCapture.all.count == 1, "a camera that's off has no zoom to set")
    }

    @Test func theFlashIsForPhotos() throws {
        let (camera, host) = try running()
        #expect(camera.hasFlash)
        camera.flashMode = .auto
        camera.flashMode = .auto
        camera.flashMode = .on
        #expect(host.calls.suffix(2) == ["setFlashMode 2", "setFlashMode 1"], "said when it changes")
        #expect(camera.flashMode == .on)
    }

    // MARK: Photos

    @Test func aPhotoIsAFileWhereTheAppSays() throws {
        let (camera, host) = try running()
        var results: [Result<CapturedPhoto, CameraError>] = []
        camera.capturePhoto(to: .caches / "shot.jpg") { results.append($0) }
        #expect(host.calls.last == "capturePhoto \(FileDirectory.caches.rawValue) shot.jpg #1")
        #expect(results.isEmpty, "nothing until the file is written")
        host.delegate.didCapturePhoto(1, width: 4032, height: 3024)
        host.delegate.didCapturePhoto(1, width: 1, height: 1)
        #expect(results.count == 1, "a request is answered once")
        #expect(try results[0].get() == CapturedPhoto(path: .caches / "shot.jpg", width: 4032, height: 3024))

        camera.capturePhoto(to: .documents / "scans" / "a.jpg") { results.append($0) }
        camera.capturePhoto(to: .documents / "scans" / "b.jpg") { results.append($0) }
        #expect(host.calls.suffix(2) == [
            "capturePhoto \(FileDirectory.documents.rawValue) scans/a.jpg #2",
            "capturePhoto \(FileDirectory.documents.rawValue) scans/b.jpg #3",
        ])
        // Answered in whatever order, each to its own.
        host.delegate.didFailCapture(3, error: CameraError.busy.rawValue)
        host.delegate.didCapturePhoto(2, width: -5, height: 10)
        #expect(error(results[1]) == .busy)
        #expect(try results[2].get() == CapturedPhoto(path: .documents / "scans" / "a.jpg", width: 0, height: 10))
        host.delegate.didFailCapture(77, error: 5)
        #expect(results.count == 3, "an answer to nothing asked is nothing")
    }

    // MARK: Video

    @Test func aRecordingBeginsAndEnds() throws {
        let (camera, host) = try running()
        var began: Result<Void, CameraError>?
        camera.startRecording(to: .caches / "clip.mp4", audio: true) { began = $0 }
        #expect(host.calls.last == "startRecording \(FileDirectory.caches.rawValue) clip.mp4 true #1")
        #expect(began == nil && !camera.isRecording)
        host.delegate.didStartRecording(1, timestamp: clock.now())
        #expect(error(began) == nil && began != nil && camera.isRecording)

        clock.advance(by: 2_500_000_000)
        #expect(camera.recordingDuration == 2.5, "worked out from when it began and the clock")

        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        var stopped: Result<CapturedVideo, CameraError>?
        camera.stopRecording { stopped = $0 }
        #expect(host.calls.last == "stopRecording" && stopped == nil, "nothing until the file is whole")
        var again: Result<CapturedVideo, CameraError>?
        camera.stopRecording { again = $0 }
        #expect(error(again) == .busy && host.calls.filter { $0 == "stopRecording" }.count == 1)

        host.delegate.didFinishRecording(1, duration: 2.6, mimeType: "video/mp4", error: 0)
        let video = CapturedVideo(path: .caches / "clip.mp4", duration: 2.6, contentType: "video/mp4")
        #expect(try #require(stopped).get() == video)
        #expect(finished == [video] && video.interruption == nil)
        #expect(!camera.isRecording && camera.recordingDuration == 2.6, "after a recording, its length")
        clock.advance(by: 5_000_000_000)
        #expect(camera.recordingDuration == 2.6)

        camera.stopRecording { again = $0 }
        #expect(error(again) == .notRunning, "nothing is being recorded")
        host.delegate.didFinishRecording(1, duration: 9, mimeType: "video/mp4", error: 0)
        #expect(finished.count == 1)
    }

    @Test func aRecordingThatDoesntBeginSaysWhy() throws {
        let (camera, host) = try running()
        var began: [Result<Void, CameraError>] = []
        camera.startRecording(to: .caches / "clip.mp4") { began.append($0) }
        #expect(host.calls.last?.hasSuffix("clip.mp4 true #1") == true, "with sound, unless told otherwise")
        host.delegate.didFailCapture(1, error: CameraError.notAuthorized.rawValue)
        #expect(error(began[0]) == .notAuthorized && !camera.isRecording)

        camera.startRecording(to: .caches / "silent.mp4", audio: false) { began.append($0) }
        #expect(host.calls.last?.hasSuffix("silent.mp4 false #2") == true)
        host.delegate.didStartRecording(2, timestamp: clock.now())
        #expect(camera.isRecording)
    }

    @Test func aRecordingCutShortIsStillAVideo() throws {
        let (camera, host) = try running()
        var finished: [CapturedVideo] = []
        camera.onRecordingFinished = { finished.append($0) }
        camera.startRecording(to: .caches / "clip.webm", audio: false) { _ in }
        host.delegate.didStartRecording(1, timestamp: clock.now())
        clock.advance(by: 4_000_000_000)

        // The app left the front: nobody asked it to stop.
        host.delegate.didChangeState(CameraState.interrupted.rawValue)
        host.delegate.didFinishRecording(1, duration: 4, mimeType: "video/webm", error: CameraError.interrupted.rawValue)
        #expect(finished == [CapturedVideo(path: .caches / "clip.webm", duration: 4, contentType: "video/webm", interruption: .interrupted)])
        #expect(!camera.isRecording && camera.state == .interrupted)
        #expect(finished[0].contentType == "video/webm", "what was written, whatever the path says")

        camera.startRecording(to: .caches / "b.mp4", audio: false) { _ in }
        host.delegate.didStartRecording(2, timestamp: clock.now())
        host.delegate.didFinishRecording(2, duration: .nan, mimeType: "video/mp4", error: 404)
        #expect(finished.last?.duration == 0 && finished.last?.interruption == .unknown)
    }

    @Test func viewsFollowARecordingOnceASecond() throws {
        let (camera, host) = try running()
        let sink = CameraSink()
        let graph = ViewGraph(Viewfinder(camera: camera), sink: sink)
        graph.update()
        func label() -> PropValue? { sink.screen?.first("Text")?.props["text"] }
        #expect(label() == "Ready")

        camera.startRecording(to: .caches / "clip.mp4", audio: false) { _ in }
        host.delegate.didStartRecording(1, timestamp: clock.now())
        graph.update()
        #expect(label() == "Recording 0")
        clock.advance(by: 1_000_000_000)
        graph.update()
        #expect(label() == "Recording 1")
        clock.advance(by: 2_000_000_000)
        graph.update()
        #expect(label() == "Recording 3")

        host.delegate.didFinishRecording(1, duration: 3.2, mimeType: "video/mp4", error: 0)
        graph.update()
        #expect(label() == "Ready")
        clock.advance(by: 3_000_000_000)
        #expect(clock.pendingCount == 0, "nothing ticks once it's over")
    }

    // MARK: The preview

    @Test func thePreviewNamesItsCamera() throws {
        let (camera, host) = try running()
        let sink = CameraSink()
        let graph = ViewGraph(Viewfinder(camera: camera), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.first("CameraPreview"))
        #expect(node.props["camera"] == .int(Int(host.id)))
        #expect(node.props["scaling"] == "fit" && node.props.count == 2 && node.children.isEmpty)

        host.delegate.didChangeZoom(4)
        graph.update()
        #expect(sink.screen?.first("CameraPreview")?.id == node.id, "the same node: the host keeps its preview")

        struct Plain: View {
            let camera: Camera
            var body: some View { CameraPreview(camera) }
        }
        let fresh = Camera()
        let plain = CameraSink()
        ViewGraph(Plain(camera: fresh), sink: plain).update()
        let made = try #require(ScriptedCapture.last)
        #expect(plain.screen?.first("CameraPreview")?.props["camera"] == .int(Int(made.id)))
        #expect(plain.screen?.first("CameraPreview")?.props["scaling"] == "fill")
        #expect(made.calls.isEmpty, "showing a camera doesn't turn it on")
    }

    // MARK: Release

    @Test func releasingTheCameraReleasesTheHosts() throws {
        var camera: Camera? = Camera()
        camera?.start()
        let id = try #require(ScriptedCapture.last).id
        #expect(ScriptedCapture.destroyed.isEmpty)
        camera = nil
        #expect(ScriptedCapture.destroyed == [id], "which turns it off")
    }

    // MARK: Async

    @MainActor @Test func capturesCanBeAwaited() async throws {
        let (camera, host) = try running()
        let taking = Task { @MainActor in
            try await camera.capturePhoto(to: .caches / "shot.jpg")
        }
        while !host.calls.contains(where: { $0.hasPrefix("capturePhoto") }) {
            await Task.yield()
        }
        host.delegate.didCapturePhoto(1, width: 800, height: 600)
        #expect(try await taking.value == CapturedPhoto(path: .caches / "shot.jpg", width: 800, height: 600))

        let recording = Task { @MainActor in
            try await camera.startRecording(to: .caches / "clip.mp4", audio: false)
            return try await camera.stopRecording()
        }
        while !host.calls.contains(where: { $0.hasPrefix("startRecording") }) {
            await Task.yield()
        }
        host.delegate.didStartRecording(2, timestamp: clock.now())
        while !host.calls.contains("stopRecording") {
            await Task.yield()
        }
        host.delegate.didFinishRecording(2, duration: 1.5, mimeType: "video/mp4", error: 0)
        #expect(try await recording.value.duration == 1.5)

        let asking = Task { @MainActor in
            await Camera.requestAccess()
        }
        while ScriptedCapture.questions.isEmpty {
            await Task.yield()
        }
        ScriptedCapture.questions[0].delegate.didChangeAccess(CameraAccess.authorized.rawValue, microphone: false)
        #expect(await asking.value == .authorized)

        // A cancelled task stops waiting; the capture itself goes on.
        let cancelled = Task { @MainActor in
            try await camera.capturePhoto(to: .caches / "late.jpg")
        }
        while !host.calls.contains(where: { $0.contains("late.jpg") }) {
            await Task.yield()
        }
        cancelled.cancel()
        await #expect(throws: CameraError.cancelled) { try await cancelled.value }
    }
}
