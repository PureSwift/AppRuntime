import DynamicFiles

/// Guest-side names for what the `CameraCapture` contract carries.

/// Which way a camera faces.
public enum CameraPosition: Int32, Sendable {

    /// Away from the user.
    case back = 1

    /// Towards the user. Its preview is mirrored; its files aren't.
    case front = 2

    /// One that's plugged in: a webcam.
    case external = 4
}

/// What a camera is doing.
public enum CameraState: Int32, Sendable {

    case stopped = 0

    case starting = 1

    case running = 2

    /// The app left the front, a call came, or another app took the
    /// camera. It runs again by itself when it can.
    case interrupted = 3

    case failed = 4
}

/// Whether a photo is taken with the flash.
public enum CameraFlashMode: Int32, Sendable {

    case off = 0

    case on = 1

    /// When the camera finds it dark.
    case auto = 2
}

/// Whether the app may use the camera, or the microphone.
public enum CameraAccess: Int32, Sendable {

    /// The user hasn't been asked.
    case notDetermined = 0

    /// Parental controls or device management prevent access.
    case restricted = 1

    /// The user refused, or the manifest doesn't declare it.
    case denied = 2

    case authorized = 3

    /// This host has no camera, or no microphone.
    case unavailable = 5
}

/// Why a camera, or a capture, failed.
public enum CameraError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The capture goes on.
    /// Hosts never send it.
    case cancelled = 1

    /// No leave for the camera, or for the microphone.
    case notAuthorized = 2

    /// No such camera on this device.
    case unavailable = 3

    /// The camera is off.
    case notRunning = 4

    /// A photo is being taken, a recording is under way, or another app
    /// has the camera.
    case busy = 5

    /// The camera was taken away during the capture.
    case interrupted = 6

    /// The file couldn't be written: no space, or not a place the app may
    /// write.
    case writeFailed = 7
}

/// A photo the camera took: a JPEG, upright, at the path asked for.
public struct CapturedPhoto: Equatable, Sendable {

    public var path: FilePath

    /// The upright picture's pixels.
    public var width: Int

    public var height: Int

    public init(path: FilePath, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }
}

/// A video the camera recorded, at the path asked for.
public struct CapturedVideo: Equatable, Sendable {

    public var path: FilePath

    /// Seconds.
    public var duration: Double

    /// What was written, whatever the path's extension: `video/mp4`
    /// where the host can, and `video/webm` from a browser that can't.
    public var contentType: String

    /// Why the recording was cut short; `nil` when the app stopped it.
    /// The file is kept either way.
    public var interruption: CameraError?

    public init(path: FilePath, duration: Double, contentType: String, interruption: CameraError? = nil) {
        self.path = path
        self.duration = duration
        self.contentType = contentType
        self.interruption = interruption
    }
}

/// How a `CameraPreview` puts the picture in its space.
public enum CameraScaling: String, Sendable {

    /// The space filled, the picture cropped.
    case fill

    /// All of it, inside the space.
    case fit
}
