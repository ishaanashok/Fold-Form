import XCTest
import RealityKit
@testable import FoldForm

@MainActor
final class ReferenceSceneTests: XCTestCase {
    func testReferenceStartsInLightModeWithPlanesAndOriginVisible() {
        let visibility = ReferenceVisibility()
        XCTAssertFalse(visibility.darkMode)
        XCTAssertFalse(visibility.planesHidden)
        XCTAssertFalse(visibility.originHidden)
        XCTAssertTrue(visibility.showRightLeft)
        XCTAssertTrue(visibility.showUpDown)
        XCTAssertTrue(visibility.showFrontBack)
    }

    func testReferencePlaneIsAnOpenWireGridRatherThanAFilledSlab() {
        let grid = ReferenceScene.gridMesh()
        let step = ReferenceScene.planeSize / 12
        let above: Float = 0.01
        let down = SIMD3<Float>(0, -1, 0)

        XCTAssertNil(grid.raycast(origin: SIMD3<Float>(step / 2, above, step / 2), direction: down),
                     "The middle of a grid cell must remain transparent")
        XCTAssertNotNil(grid.raycast(origin: SIMD3<Float>(0, above, step / 2), direction: down))
        XCTAssertNotNil(grid.raycast(origin: SIMD3<Float>(step / 2, above, 0), direction: down))
        XCTAssertNotNil(grid.raycast(origin: SIMD3<Float>(ReferenceScene.planeSize / 2, above, step / 2), direction: down),
                        "The outermost grid line should still be drawn")
    }

    func testEachPlaneUsesOneGridEntityWithoutASeparateFill() {
        let reference = ReferenceScene()
        for plane in reference.root.children.prefix(3) {
            let models = plane.children.flatMap(\.children).compactMap { $0 as? ModelEntity }
            XCTAssertEqual(models.count, 1)
        }
    }

    func testTogglesShowAndHidePlanesAndOrigin() {
        let ref = ReferenceScene()
        var v = ReferenceVisibility()
        ref.apply(v)
        XCTAssertEqual(ref.root.children.filter(\.isEnabled).count, 4)

        v.showRightLeft = false
        ref.apply(v)
        XCTAssertEqual(ref.root.children.filter(\.isEnabled).count, 3)

        v.planesHidden = true
        ref.apply(v)
        XCTAssertEqual(ref.root.children.filter(\.isEnabled).count, 1, "only the origin is left")

        v.originHidden = true
        ref.apply(v)
        XCTAssertEqual(ref.root.children.filter(\.isEnabled).count, 0)
    }
}

final class DimensionTests: XCTestCase {
    func testUnitsConvertAndTrim() {
        XCTAssertEqual(DimensionUnit.centimetres.format(metres: 0.12), "12 cm")
        XCTAssertEqual(DimensionUnit.millimetres.format(metres: 0.016), "16 mm")
        XCTAssertEqual(DimensionUnit.metres.format(metres: 0.05), "0.05 m")
        XCTAssertEqual(DimensionUnit.inches.format(metres: 0.0254), "1 in")
        XCTAssertEqual(DimensionUnit.centimetres.format(metres: 0.0537), "5.37 cm")
    }

    func testSketchShapeSegments() {
        let plane = SketchPlane(origin: .zero, u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), n: SIMD3(0, 1, 0))
        let line = DimensionBuilder.segments(for: .line(SIMD2(0, 0), SIMD2(0.03, 0.04)), on: plane)
        XCTAssertEqual(line.count, 1)
        XCTAssertEqual(line[0].length, 0.05, accuracy: 1e-6)
        let rect = DimensionBuilder.segments(for: .rectangle(SIMD2(0, 0), SIMD2(0.06, 0.02)), on: plane)
        XCTAssertEqual(rect[0].length, 0.06, accuracy: 1e-6)
        XCTAssertEqual(rect[1].length, 0.02, accuracy: 1e-6)
        let circle = DimensionBuilder.segments(for: .circle(center: SIMD2(0.1, 0.1), radius: 0.015), on: plane)
        XCTAssertEqual(circle[0].length, 0.03, accuracy: 1e-6)
        XCTAssertEqual(circle[0].midpoint, SIMD3(0.1, 0, 0.1))
    }

    func testPartSegmentsAreTheBoxSidesNearestTheCamera() {
        let mesh = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)
        let bounds = PartBounds(mesh)!
        let segs = DimensionBuilder.segments(for: bounds, cameraPosition: SIMD3(0.2, 0.3, 0.25))
        XCTAssertEqual(segs.map(\.length).sorted(), [0.016, 0.05, 0.12])
        for s in segs { XCTAssertGreaterThan(s.midpoint.y + s.midpoint.z + s.midpoint.x, -0.1) }
        let near = segs.first { abs($0.length - 0.12) < 1e-5 }!
        XCTAssertEqual(near.midpoint.y, 0.008, accuracy: 1e-6)
        XCTAssertEqual(near.midpoint.z, 0.025, accuracy: 1e-6)
    }
}

final class ExtrusionDimensionTests: XCTestCase {
    func testDepthSegmentRunsAlongTheSketchNormalFromTheNearestCorner() {
        let plane = SketchPlane(origin: .zero, u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), n: SIMD3(0, 1, 0))
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.04, 0), SIMD2(0.04, 0.04), SIMD2(0, 0.04)]
        let segs = DimensionBuilder.extrusionSegments(profiles: [square], depth: 0.012, on: plane, cameraPosition: SIMD3(1, 1, 1))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].length, 0.012, accuracy: 1e-6)
        XCTAssertEqual(segs[0].a, SIMD3(0.04, 0, 0.04))
        XCTAssertEqual(segs[0].b, SIMD3(0.04, 0.012, 0.04))
    }
}
