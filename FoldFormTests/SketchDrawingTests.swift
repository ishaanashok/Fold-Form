import XCTest
import simd
@testable import FoldForm

final class SketchDrawingTests: XCTestCase {
    func testStrokePointsAreNormalisedAndClampedToCanvas() {
        var drawing = SketchDrawing()
        drawing.addStroke([CGPoint(x: -10, y: 5), CGPoint(x: 50, y: 25), CGPoint(x: 120, y: 55)], in: CGSize(width: 100, height: 50))
        XCTAssertEqual(drawing.polylines, [[[0, 0.1], [0.5, 0.5], [1, 1]]])
    }

    func testGuideRectangleAndClearCanBeUsedWithoutDrawingGesture() {
        var drawing = SketchDrawing()
        drawing.addGuideRectangle()
        XCTAssertEqual(drawing.polylines.count, 1)
        XCTAssertEqual(drawing.polylines[0].count, 5)
        drawing.clear()
        XCTAssertTrue(drawing.polylines.isEmpty)
    }

    func testRenderingProducesPNGForEmptyAndDrawnSketch() {
        var drawing = SketchDrawing()
        XCTAssertNotNil(drawing.pngData())
        drawing.addGuideRectangle()
        let png = drawing.pngData()
        XCTAssertNotNil(png)
        XCTAssertNotEqual(png, SketchDrawing().pngData())
    }
}
