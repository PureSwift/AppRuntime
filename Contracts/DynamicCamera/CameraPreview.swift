import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Shows what a camera sees. It takes the space it's offered, and fills it,
/// cropping the picture, unless told to fit.
///
/// ```swift
/// CameraPreview(camera)
/// CameraPreview(camera, scaling: .fit)
/// ```
///
/// The front camera's preview is mirrored, as a mirror is; its photos and
/// videos aren't. A tap focuses and sets the exposure there, and a pinch
/// zooms: both are the host's, and `zoomFactor` follows a pinch. It shows
/// nothing while the camera is off.
///
/// A `CameraPreview` node has `camera`, the identifier of the host's
/// camera (`CameraCapture.identifier()`), and `scaling`. When the node
/// goes the camera stays on.
public struct CameraPreview: View {

    let camera: Camera

    let scaling: CameraScaling

    public init(_ camera: Camera, scaling: CameraScaling = .fill) {
        self.camera = camera
        self.scaling = scaling
    }

    public var body: some View {
        _RenderNodeView("CameraPreview", props: [
            "camera": .int(Int(camera.identifier)),
            "scaling": .string(scaling.rawValue),
        ])
    }
}
