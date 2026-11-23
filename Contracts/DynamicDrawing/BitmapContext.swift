import DynamicRuntime
import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A context that draws into pixels of its own, off screen: CoreGraphics'
/// bitmap context. It needs no view.
///
/// ```swift
/// guard let context = BitmapContext(width: 64, height: 64, scale: 2) else { return }
/// context.setFillColor(.orange)
/// context.fillEllipse(in: Rect(x: 0, y: 0, width: 64, height: 64))
/// let badge = context.makeImage()          // to show, or draw elsewhere
/// let png = try await context.png()        // bytes, for a file
/// ```
///
/// What's drawn goes to the host when it's read or made into an image, and
/// the state carries on from there.
public final class BitmapContext: GraphicsContext {

    /// In points.
    public let width: Double

    public let height: Double

    /// Pixels a point.
    public let scale: Double

    let bitmap: DrawingBitmapProxy

    /// Nil when the host refuses the size: every host takes 4096 pixels on a
    /// side. `opaque` starts it black instead of clear.
    public init?(width: Double, height: Double, scale: Double = 1, opaque: Bool = false) {
        guard width > 0, height > 0, scale > 0,
              let bitmap = DrawingBitmapProxy.make(width: Float(width), height: Float(height), scale: Float(scale), opaque: opaque) else {
            return nil
        }
        self.width = width
        self.height = height
        self.scale = scale
        self.bitmap = bitmap
        super.init()
    }

    /// Its pixels across: `width * scale`, rounded up.
    public var pixelWidth: Int {
        Self.pixels(width * scale)
    }

    public var pixelHeight: Int {
        Self.pixels(height * scale)
    }

    private static func pixels(_ value: Double) -> Int {
        let whole = Int(value)
        return Double(whole) < value ? whole + 1 : whole
    }

    /// Sends what's been drawn since the last time.
    func flush() {
        guard !writer.isEmpty else { return }
        bitmap.draw(writer.bytes)
        writer.reset()
        releaseRetained()
    }

    /// The bitmap as it is now, as an image that won't change: to show, or
    /// to draw in another context.
    public func makeImage() -> Image {
        flush()
        return Image(drawingImage: bitmap.image())
    }

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top:
    /// `pixelWidth` by `pixelHeight`.
    public func pixels(completion: @escaping (Result<[UInt8], DrawingError>) -> Void) {
        flush()
        bitmap.pixels(ReadBytes(completion))
    }

    /// A PNG of the bitmap.
    public func png(completion: @escaping (Result<[UInt8], DrawingError>) -> Void) {
        flush()
        bitmap.png(ReadBytes(completion))
    }

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func pixels() async throws(DrawingError) -> [UInt8] {
        try await withCallback { (callback: Callback<[UInt8], DrawingError>) in
            self.pixels { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }

    public nonisolated(nonsending) func png() async throws(DrawingError) -> [UInt8] {
        try await withCallback { (callback: Callback<[UInt8], DrawingError>) in
            self.png { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// One read's callback. The host holds it until it answers.
private final class ReadBytes: DrawingCallback {

    private var completion: ((Result<[UInt8], DrawingError>) -> Void)?

    init(_ completion: @escaping (Result<[UInt8], DrawingError>) -> Void) {
        self.completion = completion
    }

    private func answer(_ result: Result<[UInt8], DrawingError>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }

    func didRead(_ data: [UInt8]) {
        answer(.success(data))
    }

    func didMeasure(width: Float, height: Float, scale: Float) {
        answer(.failure(.unknown))
    }

    func didFail(_ code: Int32, message: String) {
        answer(.failure(DrawingError(rawValue: code) ?? .unknown))
    }
}
