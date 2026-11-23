import Testing
@testable import DynamicSwiftUI
import DynamicUI

/// Stands in for a host's image: what a module such as `DynamicDrawing`
/// gives `Image(_hostImage:owner:)`.
final class StandInImage: _HostImageOwner {
    let identifier: Int32
    init(_ identifier: Int32) {
        self.identifier = identifier
    }
    func _measure(_ completion: @escaping (Double, Double, Int32) -> Void) {
        completion(Double(identifier), 1, 0)
    }
}

@Observable
final class ZoomModel: @unchecked Sendable {
    var zoom: Double = 1
    var showsImage: Bool = true
    @ObservationIgnored var image: StandInImage? = StandInImage(7)
}

struct ZoomView: View {

    @Bindable var model: ZoomModel

    var body: some View {
        VStack {
            if model.showsImage, let image = model.image {
                ScrollView([.horizontal, .vertical]) {
                    Image(_hostImage: image.identifier, owner: image)
                        .resizable()
                        .scaledToFit()
                }
                .zoomable(1...8, scale: $model.zoom)
            }
            ScrollView {
                Text("plain")
            }
            .zoomable(0...2)
            Text("zoom \(Int(model.zoom * 100))")
        }
    }
}

@Observable
final class RowModel: @unchecked Sendable {
    var count: Int = 2
    @ObservationIgnored var images: [StandInImage] = [StandInImage(1), StandInImage(2)]
}

struct ImageRows: View {

    let model: RowModel

    var body: some View {
        VStack {
            if model.count > 0 {
                List(0..<model.count, id: \.self) { index in
                    Image(_hostImage: model.images[index].identifier, owner: model.images[index])
                }
            }
        }
    }
}

/// Images a module adds, the modifiers that fit them, and the scroll view
/// that zooms. Part of `ViewGraphTests`, which is serialized: a graph that
/// renders is the current one.
extension ViewGraphTests {

    // MARK: The image node

    @Test func aHostImageIsItsIdentifier() throws {
        let owner = StandInImage(42)
        let image = Image(_hostImage: 42, owner: owner)
        #expect(image._hostImage === owner)
        #expect(Image(systemName: "star")._hostImage == nil)

        let sink = TestSink()
        let graph = ViewGraph(image.resizable(), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.find("Image"))
        #expect(node.props["image"] == .int(42))
        #expect(node.props["resizable"] == .bool(true))
        #expect(node.props["name"] == nil)
    }

    @Test func theFrontendHoldsTheImagesATreeShows() throws {
        let model = ZoomModel()
        weak var held = model.image
        let sink = TestSink()
        let graph = ViewGraph(ZoomView(model: model), sink: sink)
        graph.update()
        model.image = nil
        #expect(held != nil, "the tree sent still shows it")

        model.showsImage = false
        graph.update()
        #expect(sink.screen?.find("Image") == nil)
        #expect(held == nil, "let go once a tree no longer shows it")
    }

    @Test func aLazyRowHoldsItsImageWhileTheListLasts() throws {
        let model = RowModel()
        weak var first = model.images[0]
        let sink = TestSink()
        let graph = ViewGraph(ImageRows(model: model), sink: sink)
        graph.update()
        let list = try #require(sink.screen?.find("List"))
        let row = try #require(graph.row(list.id, index: 0))
        #expect(row.find("Image")?.props["image"] == .int(1))
        model.images = []
        #expect(first != nil, "the host shows the row it fetched")

        model.count = 0
        graph.update()
        #expect(first == nil, "let go with the list")
    }

    // MARK: Modifiers

    @Test func aspectRatiosAndClipping() throws {
        let sink = TestSink()
        let graph = ViewGraph(VStack {
            Color.red.aspectRatio(1.5, contentMode: .fill)
            Color.blue.aspectRatio(Size(width: 4, height: 3), contentMode: .fit)
            Color.green.scaledToFit()
            Color.gray.scaledToFill().clipped()
        }, sink: sink)
        graph.update()
        let colors = try #require(sink.screen?.children)
        #expect(colors.count == 4)
        let modifiers = colors.map { $0.modifiers }
        #expect(modifiers[0].first?.kind == "aspectRatio")
        #expect(modifiers[0].first?.args["ratio"] == .double(1.5))
        #expect(modifiers[0].first?.args["contentMode"] == .string("fill"))
        #expect(modifiers[1].first?.args["ratio"] == .double(4.0 / 3.0))
        #expect(modifiers[2].first?.args["ratio"] == nil, "the content's own ratio")
        #expect(modifiers[2].first?.args["contentMode"] == .string("fit"))
        #expect(modifiers[3].map { $0.kind } == ["aspectRatio", "clipped"])
    }

    // MARK: Zooming

    @Test func aZoomingScrollViewSaysItsRangeAndScale() throws {
        let model = ZoomModel()
        model.zoom = 20
        let sink = TestSink()
        let graph = ViewGraph(ZoomView(model: model), sink: sink)
        graph.update()
        let scrolls = try #require(sink.screen?.children.filter { $0.type == "ScrollView" })
        #expect(scrolls.count == 2)
        let zooming = scrolls[0]
        #expect(zooming.props["axes"] == .string("both"))
        #expect(zooming.props["minZoom"] == .double(1))
        #expect(zooming.props["maxZoom"] == .double(8))
        #expect(zooming.props["zoom"] == .double(8), "clamped to the range")

        let plain = scrolls[1]
        #expect(plain.props["minZoom"] == .double(0.01), "the scale stays above 0")
        #expect(plain.props["maxZoom"] == .double(2))
        #expect(plain.props["zoom"] == nil, "the host keeps a scale nothing binds")
    }

    @Test func theGuestHearsTheScaleWhenTheGestureEnds() throws {
        let model = ZoomModel()
        let sink = TestSink()
        let graph = ViewGraph(ZoomView(model: model), sink: sink)
        graph.update()
        let zooming = try #require(sink.screen?.find("ScrollView"))
        #expect(graph.handle(zooming.id, kind: .change, payload: .double(2.5)))
        #expect(model.zoom == 2.5)
        graph.update()
        #expect(sink.screen?.find("Text", text: "zoom 250") != nil)
        #expect(sink.screen?.find("ScrollView")?.props["zoom"] == .double(2.5))

        #expect(graph.handle(zooming.id, kind: .change, payload: .double(0.2)))
        #expect(model.zoom == 1, "clamped to the range")
        #expect(graph.handle(zooming.id, kind: .change, payload: .string("x")))
        #expect(model.zoom == 1, "a payload that isn't a scale is ignored")
    }

    @Test func aScrollViewThatDoesntZoomSaysNothingOfIt() throws {
        let sink = TestSink()
        let graph = ViewGraph(ScrollView { Text("a") }, sink: sink)
        graph.update()
        let node = try #require(sink.screen?.find("ScrollView"))
        #expect(node.props["minZoom"] == nil)
        #expect(node.props["zoom"] == nil)
        #expect(!graph.handle(node.id, kind: .change, payload: .double(2)))
    }
}
