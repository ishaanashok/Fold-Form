import XCTest
import simd
@testable import FoldForm

final class SketchGeometryTests: XCTestCase {
    private func p(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(x, y) }
    private let tol: Float = 0.004

    func testThreeMeetingLinesMakeATriangle() {
        let shapes: [SketchShape] = [.line(p(0, 0), p(0.05, 0)), .line(p(0.05, 0), p(0.025, 0.04)), .line(p(0.025, 0.04), p(0, 0))]
        let profiles = SketchGeometry.closedProfiles(shapes, tolerance: tol)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].count, 3)
        XCTAssertGreaterThan(SketchGeometry.signedArea(profiles[0]), 0, "profiles are counter-clockwise")
    }

    func testLinesThatAlmostMeetStillClose() {
        let shapes: [SketchShape] = [.line(p(0, 0), p(0.05, 0)), .line(p(0.051, 0.001), p(0.05, 0.05)), .line(p(0.05, 0.05), p(0.001, 0.001))]
        XCTAssertEqual(SketchGeometry.closedProfiles(shapes, tolerance: tol).count, 1)
    }

    func testAnOpenChainIsNotAShape() {
        let shapes: [SketchShape] = [.line(p(0, 0), p(0.05, 0)), .line(p(0.05, 0), p(0.05, 0.05))]
        XCTAssertTrue(SketchGeometry.closedProfiles(shapes, tolerance: tol).isEmpty)
    }

    func testLoopWithADanglingTailIsNotAShape() {
        let shapes: [SketchShape] = [.line(p(0, 0), p(0.05, 0)), .line(p(0.05, 0), p(0.025, 0.04)), .line(p(0.025, 0.04), p(0, 0)), .line(p(0, 0), p(-0.03, -0.03))]
        XCTAssertTrue(SketchGeometry.closedProfiles(shapes, tolerance: tol).isEmpty)
    }

    func testRectanglesAndCirclesAreShapesOnTheirOwn() {
        let profiles = SketchGeometry.closedProfiles([.rectangle(p(0.05, 0.03), p(0, 0)), .circle(center: p(0.1, 0), radius: 0.02)], tolerance: tol)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.allSatisfy { SketchGeometry.signedArea($0) > 0 }, "a rectangle dragged backwards is still counter-clockwise")
        XCTAssertEqual(SketchGeometry.signedArea(profiles[1]), .pi * 0.02 * 0.02, accuracy: 3e-5)
    }

    func testTwoSeparateLoopsAreTwoShapes() {
        func square(_ x: Float) -> [SketchShape] {
            [.line(p(x, 0), p(x + 0.03, 0)), .line(p(x + 0.03, 0), p(x + 0.03, 0.03)), .line(p(x + 0.03, 0.03), p(x, 0.03)), .line(p(x, 0.03), p(x, 0))]
        }
        XCTAssertEqual(SketchGeometry.closedProfiles(square(0) + square(0.1), tolerance: tol).count, 2)
    }

    func testSnapPullsToTheNearestLineEnd() {
        let shapes: [SketchShape] = [.line(p(0, 0), p(0.05, 0))]
        XCTAssertEqual(SketchGeometry.snapped(p(0.052, 0.002), to: shapes, tolerance: tol), p(0.05, 0))
        XCTAssertEqual(SketchGeometry.snapped(p(0.03, 0.03), to: shapes, tolerance: tol), p(0.03, 0.03))
    }

    func testSlabExtrudesTowardTheViewer() {
        let plane = SketchPlane(origin: SIMD3(0, 0, 0.03), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), n: SIMD3(0, 0, 1))
        let mesh = SketchGeometry.slab(profile: SketchGeometry.outline(of: .rectangle(p(-0.02, -0.01), p(0.02, 0.01)))!, depth: 0.01, on: plane)
        let box = mesh.boundingBox
        XCTAssertEqual(box.min.z, 0.03, accuracy: 1e-5)
        XCTAssertEqual(box.max.z, 0.04, accuracy: 1e-5)
        XCTAssertEqual(box.max.x, 0.02, accuracy: 1e-5)
        // Outward-facing: every triangle's normal points away from the slab's centre.
        let c = mesh.center
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            let v = (0..<3).map { mesh.positions[Int(mesh.indices[start + $0])] }
            let n = simd_cross(v[1] - v[0], v[2] - v[0])
            XCTAssertGreaterThan(simd_dot(n, (v[0] + v[1] + v[2]) / 3 - c), 0)
        }
    }

    func testSlabOnASidePlaneKeepsItsWinding() {
        // Looking from +X: right = -Z, up = +Y, toward the viewer = +X.
        let u = SIMD3<Float>(0, 0, -1), v = SIMD3<Float>(0, 1, 0)
        let plane = SketchPlane(origin: .zero, u: u, v: v, n: simd_cross(u, v))
        XCTAssertEqual(plane.n, SIMD3(1, 0, 0))
        let mesh = SketchGeometry.slab(profile: SketchGeometry.outline(of: .circle(center: .zero, radius: 0.02))!, depth: 0.01, on: plane)
        let c = mesh.center
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            let t = (0..<3).map { mesh.positions[Int(mesh.indices[start + $0])] }
            XCTAssertGreaterThan(simd_dot(simd_cross(t[1] - t[0], t[2] - t[0]), (t[0] + t[1] + t[2]) / 3 - c), -1e-9)
        }
        XCTAssertEqual(mesh.boundingBox.max.x, 0.01, accuracy: 1e-5)
    }

    func testPlaneMapsARayToPlaneCoordinates() {
        let plane = SketchPlane(origin: SIMD3(0, 0, 0.02), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), n: SIMD3(0, 0, 1))
        let hit = plane.point(origin: SIMD3(0.01, 0.02, 0.3), direction: simd_normalize(SIMD3(0, 0, -1)))
        XCTAssertEqual(hit?.x ?? 9, 0.01, accuracy: 1e-6)
        XCTAssertEqual(hit?.y ?? 9, 0.02, accuracy: 1e-6)
        XCTAssertNil(plane.point(origin: SIMD3(0, 0, 0.3), direction: SIMD3(1, 0, 0)), "parallel rays miss")
        XCTAssertNil(plane.point(origin: SIMD3(0, 0, 0.3), direction: SIMD3(0, 0, 1)), "the plane behind the camera is ignored")
    }
}

@MainActor
final class SketchControllerTests: XCTestCase {
    private func plane() -> SketchPlane {
        SketchPlane(origin: .zero, u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), n: SIMD3(0, 0, 1))
    }
    private func drag(_ c: SketchController, from a: SIMD2<Float>, to b: SIMD2<Float>) {
        c.dragBegan(at: a, snapTolerance: 0.004)
        c.dragChanged(to: b, snapTolerance: 0.004)
        c.dragEnded()
    }

    func testDraggingACircleSetsItsSize() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .circle
        drag(c, from: SIMD2(0.01, 0.01), to: SIMD2(0.04, 0.01))
        XCTAssertEqual(c.shapes, [.circle(center: SIMD2(0.01, 0.01), radius: 0.03)])
        XCTAssertTrue(c.canExtrude)
    }

    func testTinyDragsAreIgnored() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .circle
        drag(c, from: .zero, to: SIMD2(0.0005, 0))
        XCTAssertTrue(c.shapes.isEmpty)
    }

    func testDrawingATriangleFromThreeLineDragsThenExtruding() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .line
        drag(c, from: SIMD2(0, 0), to: SIMD2(0.05, 0))
        drag(c, from: SIMD2(0.0502, 0.0002), to: SIMD2(0.025, 0.04))
        XCTAssertFalse(c.canExtrude, "an open chain can't extrude yet")
        drag(c, from: SIMD2(0.025, 0.04), to: SIMD2(0.001, 0.001))
        XCTAssertTrue(c.canExtrude)
        c.startExtrude()
        XCTAssertTrue(c.isExtruding)
        XCTAssertEqual(c.extrusions.count, 1)
    }

    func testDragUpMakesItThickerAndIsClamped() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .rectangle
        drag(c, from: .zero, to: SIMD2(0.04, 0.03))
        c.startExtrude()
        let start = c.depth
        c.extrudeDrag(dy: -40, worldPerPoint: 0.0005)
        XCTAssertEqual(c.depth, start + 0.02, accuracy: 1e-6)
        c.extrudeDrag(dy: -10_000, worldPerPoint: 0.0005)
        XCTAssertEqual(c.depth, SketchController.depthRange.upperBound)
        c.extrudeDrag(dy: 100_000, worldPerPoint: 0.0005)
        XCTAssertEqual(c.depth, SketchController.depthRange.lowerBound)
    }

    func testConfirmHandsBackOneSolidPerShapeAndClears() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .circle
        drag(c, from: SIMD2(0, 0), to: SIMD2(0.02, 0))
        drag(c, from: SIMD2(0.1, 0), to: SIMD2(0.12, 0))
        c.startExtrude()
        let solids = c.confirmExtrude()
        XCTAssertEqual(solids.count, 2)
        XCTAssertTrue(c.shapes.isEmpty)
        XCTAssertFalse(c.isExtruding)
        XCTAssertTrue(c.isActive, "still sketching, ready for the next shape")
    }

    func testUndoShapeAndNoDrawingWhileExtruding() {
        let c = SketchController(); c.begin(on: plane()); c.tool = .rectangle
        drag(c, from: .zero, to: SIMD2(0.04, 0.03))
        c.startExtrude()
        drag(c, from: .zero, to: SIMD2(0.1, 0.1))
        XCTAssertEqual(c.shapes.count, 1, "drags are for depth while extruding")
        c.cancelExtrude()
        c.undoShape()
        XCTAssertTrue(c.shapes.isEmpty)
    }
}

final class RayAndProjectionTests: XCTestCase {
    private let size = CGSize(width: 951, height: 669)

    func testProjectAndRayAreInverses() {
        for (yaw, pitch) in [(0.66, 0.45), (0, 0), (2.4, -0.6)] as [(Float, Float)] {
            let rig = CameraRig(target: SIMD3(0.02, -0.01, 0.03), yaw: yaw, pitch: pitch, distance: 0.3)
            let world = rig.target + rig.right * 0.04 - rig.up * 0.02
            let screen = try! XCTUnwrap(rig.project(world, in: size))
            let ray = rig.ray(at: screen, in: size)
            let t = simd_dot(world - ray.origin, rig.forward) / simd_dot(ray.direction, rig.forward)
            XCTAssertLessThan(simd_distance(ray.origin + ray.direction * t, world), 1e-5)
        }
    }

    func testTheTargetIsAtTheCentreOfTheScreen() {
        let rig = CameraRig(target: SIMD3(0.1, 0, 0), yaw: 0.3, pitch: 0.2, distance: 0.3)
        let p = try! XCTUnwrap(rig.project(rig.target, in: size))
        XCTAssertEqual(p.x, size.width / 2, accuracy: 1e-3)
        XCTAssertEqual(p.y, size.height / 2, accuracy: 1e-3)
    }

    func testPointsBehindTheCameraDoNotProject() {
        let rig = CameraRig(target: .zero, yaw: 0, pitch: 0, distance: 0.3)
        XCTAssertNil(rig.project(SIMD3(0, 0, 1), in: size))
    }

    func testNearestFace() {
        XCTAssertEqual(CameraRig(target: .zero, yaw: 0.2, pitch: 0.1, distance: 0.3).nearestFace, .front)
        XCTAssertEqual(CameraRig(target: .zero, yaw: 1.4, pitch: 0.1, distance: 0.3).nearestFace, .right)
        XCTAssertEqual(CameraRig(target: .zero, yaw: 0.2, pitch: 1.2, distance: 0.3).nearestFace, .top)
    }

    func testRaycastFindsTheNearestPartUnderThePoint() {
        let front = GeometryBuilder.box(width: 0.04, height: 0.04, depth: 0.04).translated(by: SIMD3(0, 0, 0.05))
        let behind = GeometryBuilder.box(width: 0.04, height: 0.04, depth: 0.04)
        let ray = (origin: SIMD3<Float>(0, 0, 0.3), direction: SIMD3<Float>(0, 0, -1))
        let hitFront = front.raycast(origin: ray.origin, direction: ray.direction)
        let hitBehind = behind.raycast(origin: ray.origin, direction: ray.direction)
        XCTAssertEqual(hitFront ?? 9, 0.23, accuracy: 1e-4)
        XCTAssertLessThan(hitFront ?? 9, hitBehind ?? 0)
        XCTAssertNil(front.raycast(origin: SIMD3(0.5, 0, 0.3), direction: ray.direction))
    }
}
