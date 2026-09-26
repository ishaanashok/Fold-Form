import XCTest
import simd
@testable import FoldForm

final class MeshCSGTests: XCTestCase {
    private let plate = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)   // y is thickness, centred

    private func volume(_ m: RenderMesh) -> Float { abs(m.solidProperties?.volume ?? 0) }

    func testSubtractingAThroughCircleRemovesItsVolume() {
        let plane = SketchPlane(origin: SIMD3(0, 0.008, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), n: SIMD3(0, 1, 0))
        let circle = SketchGeometry.outline(of: .circle(center: SIMD2(0, 0), radius: 0.01))!
        let cutter = SketchGeometry.cutter(profile: circle, depth: 0.03, on: plane)   // deeper than the plate
        let result = MeshCSG.subtract(plate, cutter)
        let n = Float(SketchGeometry.circleSegments)
        let disc = 0.5 * n * 0.01 * 0.01 * sin(2 * Float.pi / n)
        XCTAssertEqual(volume(result), volume(plate) - disc * 0.016, accuracy: volume(plate) * 0.002)
        XCTAssertFalse(result.indices.isEmpty)
    }

    func testAPocketRemovesOnlyItsDepth() {
        // A square cutter from the top face 0.005 down into the plate.
        let plane = SketchPlane(origin: SIMD3(0, 0.008, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), n: SIMD3(0, 1, 0))
        let square: [SIMD2<Float>] = [SIMD2(-0.01, -0.01), SIMD2(0.01, -0.01), SIMD2(0.01, 0.01), SIMD2(-0.01, 0.01)]
        let cutter = SketchGeometry.cutter(profile: square, depth: 0.005, on: plane)
        let result = MeshCSG.subtract(plate, cutter)
        XCTAssertEqual(volume(result), volume(plate) - 0.02 * 0.02 * 0.005, accuracy: volume(plate) * 0.002)
        let box = result.boundingBox
        XCTAssertEqual(box.max.y, 0.008, accuracy: 1e-5, "nothing rises above the surface")
        XCTAssertEqual(box.min.y, -0.008, accuracy: 1e-5)
    }

    func testCutMissingTheBodyChangesNothing() {
        let far = GeometryBuilder.cylinder(radius: 0.01, height: 0.01).translated(by: SIMD3(1, 0, 0))
        XCTAssertEqual(volume(MeshCSG.subtract(plate, far)), volume(plate), accuracy: 1e-9)
    }

    @MainActor func testCutFeatureCarvesTheDocumentPlate() {
        let model = AppModel()
        let before = model.document.partStudio.orderedBodyIDs.first.flatMap { model.document.partStudio.body($0) }!.mesh
        let hole = GeometryBuilder.cylinder(radius: 0.01, height: 0.05, segments: 32)
        model.addViewportCuts([hole])
        let after = model.document.partStudio.orderedBodyIDs.first.flatMap { model.document.partStudio.body($0) }!.mesh
        XCTAssertLessThan(volume(after), volume(before) * 0.98)
    }
}
