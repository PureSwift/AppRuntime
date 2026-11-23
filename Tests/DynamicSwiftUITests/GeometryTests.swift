import Foundation
import Testing
@testable import DynamicSwiftUI

/// Points, rects, transforms and the frontend's own trigonometry. No view
/// graph: a suite of its own.
@Suite struct GeometryTests {

    @Test func rectsAnswerWhatADrawingAsks() {
        let rect = Rect(x: 10, y: 20, width: 100, height: 50)
        #expect(rect.minX == 10 && rect.midX == 60 && rect.maxX == 110)
        #expect(rect.minY == 20 && rect.midY == 45 && rect.maxY == 70)
        #expect(rect.center == Point(x: 60, y: 45))
        #expect(rect.insetBy(dx: 10, dy: 5) == Rect(x: 20, y: 25, width: 80, height: 40))
        #expect(rect.insetBy(dx: 60, dy: 0).isNull, "inset past itself")
        #expect(rect.offsetBy(dx: -10, dy: 5).origin == Point(x: 0, y: 25))
        #expect(rect.contains(Point(x: 10, y: 20)) && !rect.contains(Point(x: 110, y: 20)), "the far edges are outside")

        let flipped = Rect(x: 10, y: 10, width: -5, height: -5)
        #expect(flipped.standardized == Rect(x: 5, y: 5, width: 5, height: 5))
        #expect(flipped.width == 5 && flipped.minX == 5)

        let other = Rect(x: 100, y: 60, width: 20, height: 20)
        #expect(rect.union(other) == Rect(x: 10, y: 20, width: 110, height: 60))
        #expect(rect.intersection(other) == Rect(x: 100, y: 60, width: 10, height: 10))
        #expect(rect.intersection(Rect(x: 500, y: 500, width: 1, height: 1)).isNull)
        #expect(Rect.null.union(other) == other)
        #expect(rect.contains(Rect(x: 20, y: 30, width: 10, height: 10)) && !rect.contains(other))
        #expect(Rect(size: Size(width: 3, height: 4)) == Rect(x: 0, y: 0, width: 3, height: 4))
    }

    @Test func transformsComposeAsCoreGraphicsDoes() {
        let move = AffineTransform(translationX: 10, y: 0)
        let scale = AffineTransform(scaleX: 2, y: 3)
        let point = Point(x: 1, y: 1)
        // `self`, then `other`.
        #expect(point.applying(move.concatenating(scale)) == Point(x: 22, y: 3))
        #expect(point.applying(scale.concatenating(move)) == Point(x: 12, y: 3))
        // `translatedBy` moves first, then applies the transform.
        #expect(point.applying(scale.translatedBy(x: 10, y: 0)) == Point(x: 22, y: 3))
        #expect(move.concatenating(move.inverted()).isIdentity)
        let squash = AffineTransform(scaleX: 0, y: 1)
        #expect(squash.inverted() == squash, "a transform that can't be inverted stays as it is")

        let quarter = AffineTransform(rotationAngle: .pi / 2)
        let turned = Point(x: 1, y: 0).applying(quarter)
        #expect(abs(turned.x) < 1e-12 && abs(turned.y - 1) < 1e-12, "y down: a positive angle turns clockwise on screen")
        #expect(abs(Rect(x: 0, y: 0, width: 2, height: 1).applying(quarter).standardized.size.width - 1) < 1e-12, "turned on its side")
        #expect(Size(width: 2, height: 1).applying(scale) == Size(width: 4, height: 3))
        let aliases: (DynamicSwiftUI.CGPoint, DynamicSwiftUI.CGRect, DynamicSwiftUI.CGVector, DynamicSwiftUI.CGAffineTransform) = (.zero, .zero, .zero, .identity)
        #expect(aliases.0 == Point.zero && aliases.3.isIdentity)
    }

    @Test func trigonometryMatchesLibm() {
        var angle = -20.0
        while angle <= 20 {
            #expect(abs(_Math.sin(angle) - Foundation.sin(angle)) < 1e-12, "sin \(angle)")
            #expect(abs(_Math.cos(angle) - Foundation.cos(angle)) < 1e-12, "cos \(angle)")
            angle += 0.37
        }
        for (y, x) in [(1.0, 1.0), (-1, 1), (1, -1), (-1, -1), (0, -1), (3, 0.2), (-0.001, 5), (0, 0), (2, 0), (-2, 0)] {
            #expect(abs(_Math.atan2(y, x) - Foundation.atan2(y, x)) < 1e-12, "atan2 \(y) \(x)")
        }
        #expect(_Math.sin(.infinity).isNaN && _Math.atan(.nan).isNaN)
    }
}
