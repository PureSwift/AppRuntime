import DynamicRuntime
@_exported import CGLES2

/// A place to draw with OpenGL ES 2.0, inside the app's window (§8.2).
///
/// The host owns the window and the GL context; a guest never creates
/// either. Make a surface, put a `GLSurface` view with its `identifier()`
/// in the SwiftUI tree, and draw in `SurfaceDelegate.frame`. A surface
/// whose view isn't on screen gets no frames and no input.
///
/// | Host | Context | Frames |
/// |---|---|---|
/// | iOS | EAGL, or ANGLE on Metal | `CADisplayLink` |
/// | Android | EGL | `Choreographer` |
/// | Linux | EGL (Mesa) | the compositor's frame callback |
/// | Browser | a WebGL 1 canvas | `requestAnimationFrame` |
@DynamicRuntime("org.pureswift.graphics.Surface", requires: .graphics)
public protocol Surface: AnyObject {

    static func make(_ delegate: SurfaceDelegate) -> Self

    /// What a `GLSurface` view carries to say which surface it shows.
    /// Unique among the app's surfaces while this one is alive.
    func identifier() -> Int32

    /// Hides the cursor and reports mouse movement as
    /// `SurfaceDelegate.pointerDelta`, for camera control.
    ///
    /// Returns whether capture is on afterwards: `false` on a host without
    /// a mouse, and in a browser outside an input callback. The host may
    /// end capture itself, and says so with `pointerCapture(_:captured:)`.
    func setPointerCaptured(_ captured: Bool) -> Bool
}
