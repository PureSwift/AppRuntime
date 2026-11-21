import DynamicRuntime
import DynamicCamera
import DynamicFiles
import DynamicPhotos
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example camera app: a viewfinder. It asks for the camera and shows
/// what it sees, takes a photo, records a video with sound if the user
/// allows the microphone, zooms, switches cameras, and saves what it took
/// to the user's photos, which it only adds to.

/// The closures hold the booth, which lives as long as the app does:
/// Embedded Swift has no weak or unowned references. The guest is
/// single-threaded (§6.4), which the compiler can't see.
@Observable
final class Booth: @unchecked Sendable {

    var status: String = "Not asked"

    /// What was last taken.
    var last: String = ""

    @ObservationIgnored let camera = Camera()

    @ObservationIgnored let library = PhotoLibrary.shared

    /// Counts captures, to name their files.
    @ObservationIgnored var taken = 0

    func start() {
        // However a recording ends: stopped here, or cut short because
        // the app left the front.
        camera.onRecordingFinished = { video in
            self.finished(video)
        }
        show(Camera.access)
    }

    func allow() {
        Camera.requestAccess { access in
            self.show(access)
        }
    }

    func show(_ access: CameraAccess) {
        switch access {
        case .authorized:
            status = "Ready"
            camera.start(.back)
        case .notDetermined:
            status = "Not asked"
        case .unavailable:
            status = "No camera here"
        default:
            status = "Not allowed"
        }
    }

    func shoot() {
        taken += 1
        let file: FilePath = .caches / "shot-\(taken).jpg"
        camera.capturePhoto(to: file) { result in
            switch result {
            case .success(let photo):
                self.last = "Photo \(photo.width)x\(photo.height)"
                self.keep(file, isVideo: false)
            case .failure(let error):
                self.report(error)
            }
        }
    }

    /// Starts a recording, or ends the one under way.
    func record() {
        if camera.isRecording {
            camera.stopRecording { result in
                if case .failure(let error) = result {
                    self.report(error)
                }
            }
            return
        }
        // With sound if the user allows the microphone, and without if
        // they don't: the choice is made here, not by the host.
        Camera.requestMicrophoneAccess { access in
            self.taken += 1
            let sound = access == .authorized
            self.camera.startRecording(to: .caches / "clip-\(self.taken).mp4", audio: sound) { result in
                switch result {
                case .success:
                    self.status = sound ? "Recording with sound" : "Recording without sound"
                case .failure(let error):
                    self.report(error)
                }
            }
        }
    }

    func finished(_ video: CapturedVideo) {
        last = "Video \(Int(video.duration))s " + video.contentType + (video.interruption == nil ? "" : ", cut short")
        keep(video.path, isVideo: true)
    }

    /// Copies a capture into the user's photos. The app declares adding
    /// alone, so it's asked for no more than that.
    func keep(_ file: FilePath, isVideo: Bool) {
        library.requestAccess { access in
            guard access.allowsAdding else {
                self.status = "Not saved: no access to Photos"
                return
            }
            let done: (Result<PhotoAsset?, PhotoLibraryError>) -> Void = { result in
                switch result {
                case .success:
                    self.status = "Saved to Photos"
                case .failure(let error):
                    self.status = "Not saved: error \(error.rawValue)"
                }
            }
            if isVideo {
                self.library.add(video: file, completion: done)
            } else {
                self.library.add(photo: file, completion: done)
            }
        }
    }

    func flip() {
        camera.start(camera.position == .back ? .front : .back)
    }

    /// Twice as close, as far as the camera goes.
    func zoomIn() {
        camera.zoomFactor = camera.zoomFactor * 2
    }

    func report(_ error: CameraError) {
        switch error {
        case .notAuthorized: status = "Not allowed"
        case .notRunning: status = "The camera is off"
        case .busy: status = "Busy"
        case .interrupted: status = "Interrupted"
        case .writeFailed: status = "Couldn't write the file"
        default: status = "Camera error \(error.rawValue)"
        }
    }

    /// "Back camera, running, x2.0".
    static func describe(_ camera: Camera) -> String {
        let side: String
        switch camera.position {
        case .back: side = "Back"
        case .front: side = "Front"
        case .external: side = "External"
        }
        let state: String
        switch camera.state {
        case .stopped: state = "off"
        case .starting: state = "starting"
        case .running: state = "running"
        case .interrupted: state = "interrupted"
        case .failed: state = "failed"
        }
        // Tenths, without a formatter.
        let tenths = Int(camera.zoomFactor * 10 + 0.5)
        return side + " camera, " + state + ", x\(tenths / 10).\(tenths % 10)" + (camera.hasFlash ? ", flash" : "")
    }
}

struct ContentView: View {

    let booth: Booth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CameraPreview(booth.camera)
                .frame(height: 320)
            Text(Booth.describe(booth.camera))
                .accessibilityIdentifier("camera")
            Text(booth.camera.isRecording ? "Recording \(Int(booth.camera.recordingDuration))s" : "Not recording")
                .accessibilityIdentifier("recording")
            HStack(spacing: 8) {
                Button("Allow") { booth.allow() }
                Button("Shoot") { booth.shoot() }
                Button(booth.camera.isRecording ? "Stop" : "Record") { booth.record() }
                Button("Flip") { booth.flip() }
                Button("Zoom") { booth.zoomIn() }
            }
            Text(booth.last)
                .accessibilityIdentifier("last")
            Text(booth.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleCameraApp: App {

    let booth = Booth()

    init() {
        booth.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(booth: booth)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleCameraMain() -> rt_status {
    Runtime.main { ExampleCameraApp.run() }
}
