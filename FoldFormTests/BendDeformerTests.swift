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
        // At the far edge (x = +width/2), a 90-degree bend should rotate that edge to x ≈ 0, y ≈ +width/2.
        guard let farVertexIndex = mesh.positions.indices.max(by: { mesh.positions[$0].x < mesh.positions[$1].x }) else {
            return XCTFail("no vertices")
        }
        let original = mesh.positions[farVertexIndex]
        let transformed = bent.positions[farVertexIndex]
        XCTAssertEqual(transformed.x, 0, accuracy: 1e-4)
        XCTAssertEqual(transformed.y, original.y + abs(original.x), accuracy: 1e-4)
        XCTAssertEqual(transformed.z, original.z)
    }

    func testNoPoppingContinuousAcrossSmallAngleSteps() {
        let mesh = plate()
        var previous = BendDeformer.deform(mesh, bendAngleRadians: 0)
        for step in 1...90 {
            let angle = Double(step) * (.pi / 2) / 90
            let current = BendDeformer.deform(mesh, bendAngleRadians: angle)
            for i in current.positions.indices {
                XCTAssertLessThan(simd_distance(current.positions[i], previous.positions[i]), 0.01)
            }
            previous = current
        }
    }
}
