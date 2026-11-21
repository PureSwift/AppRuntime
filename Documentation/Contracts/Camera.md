# Camera

**Status:** a design for review. Nothing here is implemented.

Module `DynamicCamera`: a live preview, photos, and video with sound.

Putting what it took where the user keeps their photos is the
[photo library](Photos.md)'s, in a module of its own. An app that takes
a photo of a receipt doesn't ask its host for the library.

| Contract | Kind | iOS / macOS | Android | Linux | Browser |
|---|---|---|---|---|---|
| `CameraCapture` | contract, `requires: .camera` | an `AVCaptureSession` | CameraX | the camera portal, through a GStreamer pipeline | `getUserMedia` |
| `CameraCaptureDelegate` | callback: what the camera did | | | | |

Guest-side Swift:

- **`Camera`**: the observable camera app code uses.
- **`CameraPreview`**: the SwiftUI view that shows what it sees.
- `CameraPosition`, `CameraFlashMode`, `CameraState`, `CameraAccess`,
  `CapturedPhoto`, `CapturedVideo`, `CameraError`.

The render IR gains one node, `CameraPreview`.

## What shapes it

- **The pictures are the host's.** No frame crosses to the guest. The
  host shows the preview, writes a photo or a video to a file, and tells
  the guest when it's there. This is the [media player](MediaPlayer.md)
  turned round.
- **A capture is a file.** The app says where, in its own directories.
  What it does with it then is `Files`' business, or the
  [photo library](Photos.md)'s.
- **The user is asked, twice.** For the camera, and for the microphone if
  a video has sound. Each has a capability and a usage text.
- **The camera is on only while the app is in front.** Every platform
  takes it away in the background, and shows the user that it's on.
- **The preview's gestures are the host's.** A tap to focus is on the
  preview and never reaches the guest.
- **Lenses are a zoom.** A phone's wide, main and telephoto lenses are
  one camera with a range of zoom. The host changes lens as the zoom
  crosses from one to the next.

## For a guest

```swift
import SwiftUI
import DynamicCamera
import DynamicPhotos        // to save what's taken

let camera = Camera()

guard await Camera.requestAccess() == .authorized else { return }
camera.start(.back)

struct Viewfinder: View {
    let camera: Camera
    var body: some View {
        CameraPreview(camera)
    }
}

let photo = try await camera.capturePhoto(to: .caches / "shot.jpg")
try await PhotoLibrary.shared.add(photo: .caches / "shot.jpg")
```

### The camera

| `Camera` | |
|---|---|
| `start(_:)` | turns on the back or the front camera. Starting again switches |
| `stop()` | turns it off |
| `state` | observable: `.stopped`, `.starting`, `.running`, `.interrupted`, `.failed` |
| `position` | observable: `.back`, `.front`, `.external` |
| `zoomFactor` | observable and settable: 1 is the main lens |
| `zoomRange` | observable: what this camera can do, such as `0.5...15` |
| `hasFlash`, `flashMode` | `.off`, `.on`, `.auto`, for photos |
| `isRecording`, `recordingDuration` | observable |
| `onRecordingFinished` | called with the video when a recording ends, however it ended |
| `error` | why it's `.failed` |

- **`Camera.positions`** says which cameras this device has.
- **One camera at a time.** Starting a second `Camera` stops the first.
- **`.interrupted`** is the app leaving the front, a phone call, or
  another app taking the camera. It runs again by itself when it can.
- **A `Camera` is separate from its preview.** It runs, and can take a
  photo, with no view showing. Releasing it turns it off.

### Access

| | |
|---|---|
| `Camera.access` | `.notDetermined`, `.denied`, `.restricted`, `.authorized`, `.unavailable`. Never asks |
| `Camera.requestAccess()` | asks the user if they haven't decided |
| `Camera.microphoneAccess`, `Camera.requestMicrophoneAccess()` | the same, for sound |

`start` without access fails: `state` is `.failed`, with `notAuthorized`.

### The preview

```swift
CameraPreview(camera)                       // fills its space, cropping
CameraPreview(camera, scaling: .fit)        // all of the picture
```

- It takes the space it's offered.
- **The front camera's preview is mirrored,** as a mirror is. Its photos
  and videos aren't.
- **A tap focuses** and sets the exposure there. A pinch zooms, and
  `zoomFactor` follows.
- It shows nothing while the camera is off.

### Photos

```swift
let photo = try await camera.capturePhoto(to: .caches / "shot.jpg")
// photo.width, photo.height
```

- **A JPEG,** at the camera's full size, written to the path given,
  replacing what's there.
- **It's upright.** Whichever way the device was held, the file shows
  the right way up in anything that reads it.
- **`flashMode`** is used if the camera has a flash.
- **One at a time.** A second while one is being taken fails with
  `busy`.

### Video

```swift
try await camera.startRecording(to: .caches / "clip.mp4", audio: true)
// …
let video = try await camera.stopRecording()
// video.duration, video.contentType
```

- **`startRecording` returns when recording has begun.** `stopRecording`
  returns when the file is whole.
- **MP4, with H.264 and AAC, where the host can.** A browser may only
  make WebM. `contentType` says which was written, whatever the path's
  extension.
- **`audio: true` needs the microphone:** `.microphone` in the manifest,
  and the user's leave. Without either it fails with `notAuthorized`,
  and nothing is recorded.
- **A recording ends by itself** when the camera is interrupted or
  stopped, or the disk fills. The file is kept, and `onRecordingFinished`
  is called with it.
- **No photos while recording.**

### Errors

| `CameraError` | |
|---|---|
| `notAuthorized` | no leave for the camera, or for the microphone |
| `unavailable` | no such camera on this device |
| `notRunning` | the camera is off |
| `busy` | a photo is being taken, a recording is under way, or another app has the camera |
| `interrupted` | the camera was taken away during the capture |
| `writeFailed` | the file couldn't be written: no space, or not a place the app may write |
| `cancelled` | the task waiting was cancelled |

## The contracts

```swift
@DynamicRuntime("org.pureswift.camera.Capture", requires: .camera)
public protocol CameraCapture: AnyObject {

    /// A camera that's off. The host keeps `delegate` while it lives, and
    /// turns the camera off when the guest releases it.
    static func make(_ delegate: CameraCaptureDelegate) -> Self

    /// Bits: 1 back, 2 front, 4 external.
    static func positions() -> Int32
    /// A `CameraAccess` raw value. Never asks.
    static func access() -> Int32
    static func microphoneAccess() -> Int32
    /// Answered by `didChangeAccess`.
    static func requestAccess(_ delegate: CameraCaptureDelegate)
    static func requestMicrophoneAccess(_ delegate: CameraCaptureDelegate)

    /// What a `CameraPreview` node carries to say which camera it shows.
    func identifier() -> Int32

    /// A `CameraPosition` raw value. Answered by `didStart` or `didFail`.
    func start(_ position: Int32)
    func stop()
    func setZoom(_ factor: Double)
    /// A `CameraFlashMode` raw value.
    func setFlashMode(_ mode: Int32)

    // A file as `Files` names it: a `FileDirectory` raw value and a path.

    /// Answered by `didCapturePhoto` or `didFailCapture`, with `request`.
    func capturePhoto(_ directory: Int32, path: String, request: Int32)
    /// Answered by `didStartRecording` or `didFailCapture`.
    func startRecording(_ directory: Int32, path: String, audio: Bool, request: Int32)
    /// Answered by `didFinishRecording`.
    func stopRecording()
}

@DynamicCallback("org.pureswift.camera.CaptureDelegate")
public protocol CameraCaptureDelegate: AnyObject {
    /// `microphone` says which was asked about.
    func didChangeAccess(_ access: Int32, microphone: Bool)
    /// A `CameraState` raw value.
    func didChangeState(_ state: Int32)
    /// The camera is on.
    func didStart(_ position: Int32, minimumZoom: Double, maximumZoom: Double, hasFlash: Bool)
    /// The user pinched, or the guest set it.
    func didChangeZoom(_ factor: Double)
    /// A `CameraError` raw value.
    func didFail(_ error: Int32)
    /// The file is written. Sizes are the upright picture's pixels.
    func didCapturePhoto(_ request: Int32, width: Int32, height: Int32)
    /// Recording began at `timestamp`: nanoseconds on the `Clock.now()`
    /// timeline.
    func didStartRecording(_ request: Int32, timestamp: Int64)
    /// The file is whole. `error` is 0, or why the recording was cut short.
    func didFinishRecording(_ request: Int32, duration: Double, mimeType: String, error: Int32)
    func didFailCapture(_ request: Int32, error: Int32)
}
```

### Rules every host follows

- **Everything is reported on the main thread.**
- **One camera is on at a time.** Starting another stops the one that
  was, which reports `stopped`.
- **The camera is off while the app isn't in front.** The host reports
  `interrupted`, and `running` again when the camera is back. It ends a
  recording first.
- **The system's own sign that the camera is on is never hidden.**
- **A photo is a JPEG and displays upright.** A video is MP4 with H.264
  and AAC where the host can make one; otherwise what it can, said in
  `mimeType`.
- **The front camera's preview is mirrored. No file is.**
- **A file is found as `Files` finds it,** so a document the user picked
  works. It's written off the main thread, and the answer comes when it's
  whole.
- **A recording that's cut short is still a file.** `didFinishRecording`
  says why it ended.
- **Zoom is clamped** to the camera's range, and `didChangeZoom` says
  what it became.
- **Sound is recorded only with the microphone's capability and the
  user's leave.** The host doesn't record a silent video instead.
- **Releasing the `CameraCapture` turns the camera off,** and ends a
  recording, keeping its file.

## The render IR

| Type | Props | Children | Events |
|---|---|---|---|
| `CameraPreview` | `camera` (int: a `CameraCapture`'s `identifier()`), `scaling` (`fill`, `fit`) | — | none here: the camera reports through its contract |

Put the camera's preview there. Taps and pinches inside the node are the
preview's: a tap focuses, a pinch zooms. When the node goes the camera
stays on.

## The shared host

`HostCameraCapture`, in a new `RuntimeCamera`, over a host's
`CameraPlatform` and the `CameraEngine` it makes, as the media player's
shared host is over its platform and engines:

```swift
public protocol CameraEngine: AnyObject {            // main thread
    func start(_ position: CameraPosition)
    func stop()
    func setZoom(_ factor: Double)
    func setFlashMode(_ mode: CameraFlashMode)
    /// Writes a JPEG at an absolute path, upright.
    func capturePhoto(to path: String, completion: @escaping (Result<CapturedPhoto, CameraError>) -> Void)
    func startRecording(to path: String, audio: Bool, completion: @escaping (CameraError?) -> Void)
    func stopRecording()
}

HostCameraCapture.platform = MyCameras()
HostCameraCapture.allowsMicrophone = declared.contains(.microphone)
HostCameraCapture.clock = runtime.clock
HostCameraModule.register(in: runtime)

HostCameraCapture.applicationDidEnterBackground()
HostCameraCapture.applicationWillEnterForeground()
HostCameraCapture.camera(for: identifier)?.engine    // for the renderer
```

- It finds each file through `HostFiles` before an engine sees a path,
  and refuses one the app may not write.
- It keeps one camera on, one photo at a time and one recording, and
  answers each request once.
- It refuses sound without the capability, turns the camera off for the
  background and on again, and ends a recording when it must.
- **Without a platform, there's no camera:** `positions` is none, access
  is `.unavailable`, and `start` fails.

## The manifest

```swift
capabilities: [
    .camera(usage: "Takes photos and videos."),
    .microphone(usage: "Records sound with your videos."),
]
```

`.camera` is there already. `.microphone` is new. A camera that saves to
the user's photos also declares `.photoLibrary(.addOnly, usage:)`
([Photo library](Photos.md)).

| | `.camera` | `.microphone` |
|---|---|---|
| iOS / macOS | `NSCameraUsageDescription` | `NSMicrophoneUsageDescription` |
| Android | `CAMERA`, and `uses-feature camera` | `RECORD_AUDIO` |
| Linux | the camera portal | the sound server's socket, for recording |
| Browser | asked when the camera starts | asked when a recording with sound starts |

## Per host

From each platform's documentation. None of it has been tried.

| | Notes |
|---|---|
| iOS / macOS | An `AVCaptureSession` with the widest virtual device the position has (`builtInTripleCamera` and its kin), whose `videoZoomFactor` changes lens by itself; 1 is the main lens. `AVCaptureVideoPreviewLayer` in the node. `AVCapturePhotoOutput` with `AVCapturePhotoSettings.flashMode`; the JPEG carries its orientation. `AVCaptureMovieFileOutput` for video. A tap sets `focusPointOfInterest` and `exposurePointOfInterest`. Interruption notifications are `interrupted`. |
| Android | CameraX: `Preview` into a `PreviewView`, `ImageCapture` with a target rotation, and `VideoCapture` with a `Recorder`. `CameraControl.setZoomRatio`, and `startFocusAndMetering` on a tap. The lifecycle the camera is bound to is the app's being in front. |
| Linux | The camera portal gives a PipeWire node. A GStreamer pipeline from `pipewiresrc`: one branch to the player's texture for the preview, `jpegenc` for a photo, `x264enc` and an AAC encoder into `mp4mux` for video. Zoom is a crop unless the camera has its own. |
| Browser | `navigator.mediaDevices.getUserMedia`, shown in a `<video>` element. A photo is a frame drawn to a canvas, or `ImageCapture.takePhoto` where there is one. `MediaRecorder` for video, in MP4 where `isTypeSupported` says so and WebM otherwise. Zoom is the track's `zoom` constraint where the camera has one. There's no flash to speak of. |

## Not in this design

- **Frames for the guest:** filters, a scanner of its own, machine
  vision. No picture crosses.
- **Scanning codes.** QR codes and barcodes are a host's to read, and a
  contract of their own.
- **Manual controls:** exposure, ISO, white balance, focus by distance.
- **Formats:** HEIC, RAW, Live Photos, depth and portrait, HDR by choice.
- **Choosing a video's size or frame rate,** slow motion, time-lapse, and
  pausing a recording.
- **A light while recording.** `flashMode` is for photos.
- **Choosing a lens,** or one of several external cameras, by name.
- **Recording sound alone.** That's with the [audio](Audio.md) draft.
- **The user's photos.** Saving to them, picking from them and browsing
  them are the [photo library](Photos.md)'s.
- **The system's own camera screen,** for an app that wants one photo
  and no viewfinder of its own.
- **Where the photo was taken.** A camera that tags places needs
  [location](Location.md) too, and writes the tag itself.

## Questions for review

1. **Names:** `Camera` and `CameraPreview`, contract `CameraCapture`,
   module `DynamicCamera`. AVFoundation's own names are too many to
   follow.
2. **Saving to the user's photos isn't here.** It's the
   [photo library](Photos.md)'s add-only level, in a module of its own.
3. **Photos are JPEG.** HEIC is smaller and isn't everywhere.
4. **A video is MP4 where the host can,** and the host says what it
   wrote. A browser host may give WebM, which the media player needn't
   play everywhere.
5. **Focus and pinch are the preview's own,** in the host. The guest has
   `zoomFactor` and nothing for focus.
6. **Lenses are a zoom,** not a choice.
7. **A new `.microphone` capability.** A video with sound needs it; one
   without doesn't.
8. **No stand-in camera.** A host without one says so. The tests keep an
   engine of their own, as the media player's do.
