import DynamicRuntime
import DynamicDrawing
import DynamicFiles
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example drawing app: a gauge drawn in a canvas, a bar chart with
/// labels measured to fit, a star that's a shape of its own, and a badge
/// drawn off screen into a bitmap, shown and saved as a PNG.
@Observable
final class Board {

    /// 0 to 1.
    var level: Double = 0.4

    var sales: [Double] = [3, 7, 5, 9]

    var badge: Image? = nil

    var status: String = ""

    static let months = ["Jan", "Feb", "Mar", "April"]

    static let badgeFile = FilePath(.documents, "badge.png")

    func step(_ by: Double) {
        level = Swift.max(0, Swift.min(1, level + by))
    }

    /// Draws a badge into a bitmap of its own, shows it, and saves it.
    func makeBadge() {
        guard let context = BitmapContext(width: 64, height: 64, scale: 2) else {
            status = "This host makes no bitmaps"
            return
        }
        context.setFillColor(.orange)
        context.fillEllipse(in: Rect(x: 0, y: 0, width: 64, height: 64))
        context.setFont(.system(size: 24, weight: .bold))
        context.setFillColor(.white)
        context.draw("\(Int(level * 100))", at: Point(x: 32, y: 32), anchor: .center)
        badge = context.makeImage()
        context.png { result in
            switch result {
            case .success(let png):
                FileManager.default.write(png, to: Self.badgeFile) { written in
                    switch written {
                    case .success:
                        self.status = "Saved badge.png, \(png.count) bytes"
                    case .failure(let error):
                        self.status = "Couldn't save the badge: error \(error.rawValue)"
                    }
                }
            case .failure(let error):
                self.status = "Couldn't encode the badge: error \(error.rawValue)"
            }
        }
    }
}

/// A five-pointed star, from its frame.
struct Star: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        let center = rect.center
        let outer = Swift.min(rect.width, rect.height) / 2
        for index in 0..<10 {
            let radius = index % 2 == 0 ? outer : outer * 0.4
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
            let point = Point(x: center.x + radius * _Math.cos(angle), y: center.y + radius * _Math.sin(angle))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

struct Gauge: View {

    let level: Double

    var body: some View {
        Canvas { context, size in
            let bounds = Rect(size: size).insetBy(dx: 8, dy: 8)
            let radius = Swift.min(bounds.width, bounds.height) / 2
            context.setLineWidth(12)
            context.setLineCap(.round)
            context.setStrokeColor(.gray)
            context.addArc(center: bounds.center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.strokePath()
            context.setStrokeColor(.accentColor)
            context.addArc(center: bounds.center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * level, clockwise: false)
            context.strokePath()
            context.setFont(.system(size: 28, weight: .semibold))
            context.setFillColor(.primary)
            context.draw("\(Int(level * 100))%", at: bounds.center, anchor: .center)
        }
        .frame(width: 120, height: 120)
    }
}

struct Chart: View {

    let values: [Double]

    var body: some View {
        Canvas { context, size in
            let font = Font.caption
            let labelHeight = font.measure("Jan").height
            let top = values.max() ?? 1
            let slot = size.width / Double(Swift.max(values.count, 1))
            for index in values.indices {
                let height = (size.height - labelHeight - 4) * values[index] / top
                let bar = Rect(x: Double(index) * slot + 4, y: size.height - labelHeight - 4 - height, width: slot - 8, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .accentColor)
                // A label that doesn't fit its slot is cut to its first
                // letters.
                var label = Board.months[index % Board.months.count]
                while label.count > 1, font.measure(label).width > slot {
                    label.removeLast()
                }
                context.setFont(font)
                context.setFillColor(.secondary)
                context.draw(label, at: Point(x: bar.midX, y: size.height), anchor: .bottom)
            }
        }
        .frame(height: 100)
    }
}

struct ContentView: View {

    @Bindable var board: Board

    var body: some View {
        VStack(spacing: 12) {
            Gauge(level: board.level)
            HStack(spacing: 8) {
                Button("Less") { board.step(-0.1) }
                Button("More") { board.step(0.1) }
            }
            Chart(values: board.sales)
            Star().fill(.yellow)
                .frame(width: 40, height: 40)
            Button("Make Badge") { board.makeBadge() }
            if let badge = board.badge {
                badge.resizable()
                    .frame(width: 64, height: 64)
            }
            Text(board.status)
                .accessibilityIdentifier("status")
        }
        .padding()
    }
}

struct ExampleDrawingApp: App {

    let board = Board()

    var body: some Scene {
        WindowGroup {
            ContentView(board: board)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleDrawingMain() -> rt_status {
    Runtime.main { ExampleDrawingApp.run() }
}
