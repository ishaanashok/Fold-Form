import XCTest
import simd
@testable import FoldForm

final class GeometryKernelTests: XCTestCase {
    let kernel = ProceduralGeometryKernel()

    func testExtrudeRectangleProducesClosedManifoldTriangleList() throws {
        let profile = PlanarProfile.rectangle(width: 0.1, height: 0.02)
        let params = ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new)
        let solid = try kernel.extrude(profile, params, into: [:])
        XCTAssertFalse(solid.mesh.positions.isEmpty)
        XCTAssertEqual(solid.mesh.indices.count % 3, 0)
    }

    func testExtrudeWithZeroDistanceThrows() {
        let profile = PlanarProfile.rectangle(width: 0.1, height: 0.02)
        let params = ExtrudeParameters(termination: .blind(distance: 0), resultType: .new)
        XCTAssertThrowsError(try kernel.extrude(profile, params, into: [:]))
    }

    func testCreateHoleOnPlateProducesLargerMeshWithoutErrors() throws {
        let profile = PlanarProfile.rectangle(width: 0.1, height: 0.02)
        let plate = try kernel.extrude(profile, ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new), into: [:])
        let hole = HoleDefinition(center: .zero, diameter: 0.02, type: .simple, throughAll: true)
        let result = try kernel.createHole(hole, in: plate)
        XCTAssertGreaterThan(result.mesh.positions.count, plate.mesh.positions.count)
        if case .prismWithHoles(_, _, _, let holes) = result.kind {
            XCTAssertEqual(holes.count, 1)
        } else {
            XCTFail("expected prismWithHoles kind")
        }
    }

    func testBlindHoleIsUnsupportedAndFailsClearly() {
        let profile = PlanarProfile.rectangle(width: 0.1, height: 0.02)
        guard let plate = try? kernel.extrude(profile, ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new), into: [:]) else {
            return XCTFail("setup failed")
        }
        let hole = HoleDefinition(center: .zero, diameter: 0.02, type: .simple, throughAll: false, depth: 0.01)
        XCTAssertThrowsError(try kernel.createHole(hole, in: plate)) { error in
            XCTAssertEqual(error as? GeometryKernelError, .unsupportedOperation("Blind (non-through) holes"))
        }
    }

    func testFilletIsExplicitlyUnsupported() throws {
        let box = try kernel.makePrimitive(.box(width: 0.1, height: 0.1, depth: 0.1))
        XCTAssertThrowsError(try kernel.fillet(FilletDefinition(edgeIDs: [], radius: 0.01), in: box))
    }

    func testTriangulatorHandlesSquare() {
        let square: [SIMD2<Double>] = [.init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)]
        let triangles = Triangulator.triangulate(square)
        XCTAssertEqual(triangles.count, 6) // two triangles
    }

    func testPolygonBridgeProducesSimplePolygonAroundHole() throws {
        let outer: [SIMD2<Double>] = [.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)]
        let hole: [SIMD2<Double>] = (0..<16).map { i in
            let a = Double(i) / 16 * 2 * .pi
            return .init(cos(a) * 0.2, sin(a) * 0.2)
        }
        let bridged = try PolygonBridge.bridgeHole(outer: outer, hole: hole)
        XCTAssertEqual(bridged.count, outer.count + hole.count + 2)
        let triangles = Triangulator.triangulate(bridged)
        XCTAssertFalse(triangles.isEmpty)
    }
}
