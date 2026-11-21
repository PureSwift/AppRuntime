import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Shows an asset, at whatever size it's given: a thumbnail in a grid, the
/// whole picture on a whole screen.
///
/// ```swift
/// LazyVGrid(columns: columns) {
///     ForEach(assets) { asset in
///         PhotoView(asset)
///             .frame(height: 110)
///     }
/// }
///
/// PhotoView(asset, scaling: .fit)
/// ```
///
/// The host draws it, from the system's own copies, and sharpens it as a
/// better one arrives: no pixel crosses to the guest. A video shows its
/// first frame; to play it, ask the library for its file. It takes the
/// space it's offered, so in a grid give it a height.
///
/// A `Photo` node has `asset`, the asset's identifier, and `scaling`. An
/// asset the app may not see, or one that's gone, draws nothing.
public struct PhotoView: View {

    let asset: String

    let scaling: PhotoScaling

    /// It fills its space and crops, unless told to fit.
    public init(_ asset: PhotoAsset, scaling: PhotoScaling = .fill) {
        self.asset = asset.id
        self.scaling = scaling
    }

    /// An asset by the identifier an app kept.
    public init(assetID: String, scaling: PhotoScaling = .fill) {
        self.asset = assetID
        self.scaling = scaling
    }

    public var body: some View {
        _RenderNodeView("Photo", props: [
            "asset": .string(asset),
            "scaling": .string(scaling.rawValue),
        ])
    }
}
