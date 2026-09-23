import XCTest
import simd
@testable import FoldForm

final class BendDeformerTests: XCTestCase {
    private func plate() -> RenderMesh {
        GeometryBuilder.box(width: 0.1, height: 0.01, depth: 0.1)
    }

    func testZeroAngleIsUnchanged() {
        let mesh = plate()
        let bent = BendDeformer.deform(mesh, bendAngleRadians: 0)
        XCTAssertEqual(mesh.positions, bent.positions)
    }

    func testNinetyDegreeFormsRightAngle() {
        let mesh = plate()
        let bent = BendDeformer.deform(mesh, bendAngleRadians: .pi / 2)
        // The mesh is intentionally split at x = 0. At 90°, both outer edges have
        // rotated into the crease neighborhood, while the seam remains represented
        // in the topology instead of being stretched across by a single triangle.
        XCTAssertTrue(bent.positions.contains {
            abs($0.x) < 0.006 && $0.y > 0.045 && abs($0.z) < 0.051
        })
        XCTAssertTrue(bent.positions.contains {
            abs($0.x) < 0.006 && $0.y > 0.045 && abs($0.z) > 0.049
        })
    }

    func testNoPoppingContinuousAcrossSmallAngleSteps() {
        let mesh = plate()
        var previous = BendDeformer.deform(mesh, bendAngleRadians: 0)
        for step in 1...90 {
            let angle = Double(step) * (.pi / 2) / 90
            let current = BendDeformer.deform(mesh, bendAngleRadians: angle)
            // The crease splitter can legitimately change vertex count as a triangle
            // enters/leaves the seam. Compare the spatial envelope rather than indices.
            XCTAssertLessThan(
                simd_distance(current.boundingBox.min, previous.boundingBox.min),
                0.01
            )
            XCTAssertLessThan(
                simd_distance(current.boundingBox.max, previous.boundingBox.max),
                0.01
            )
            previous = current
        }
    }

    func testCreaseIndicatorUsesThePartLocalAxis() {
        let mesh = plate()
        let (start, end) = BendDeformer.creaseIndicatorEndpoints(mesh)

        XCTAssertEqual(start.x, 0, accuracy: 1e-6)
        XCTAssertEqual(start.y, 0, accuracy: 1e-6)
        XCTAssertEqual(end.x, 0, accuracy: 1e-6)
        XCTAssertEqual(end.y, 0, accuracy: 1e-6)
        XCTAssertEqual(start.z, mesh.boundingBox.min.z, accuracy: 1e-6)
        XCTAssertEqual(end.z, mesh.boundingBox.max.z, accuracy: 1e-6)
    }
}
