import XCTest
import simd
@testable import FoldForm

final class CameraRigTests: XCTestCase {
    private func rig(yaw: Float = 0.66, pitch: Float = 0.45, target: SIMD3<Float> = .zero) -> CameraRig {
        CameraRig(target: target, yaw: yaw, pitch: pitch, distance: 0.3)
    }

    func testCameraLooksAtTheTarget() {
        let r = rig(target: SIMD3<Float>(0.02, 0.01, -0.03))
        let toTarget = simd_normalize(r.target - r.position)
        XCTAssertLessThan(simd_distance(toTarget, r.forward), 1e-5)
    }

    func testPanFollowsTheFingersOnScreen() {
        var r = rig(yaw: 0, pitch: 0)   // camera on +Z looking down -Z: right = +X, up = +Y
        r.pan(dx: 100, dy: 0, viewportHeight: 669)
        // Dragging right moves the model right, so the camera target moves left.
        XCTAssertLessThan(r.target.x, 0)
        XCTAssertEqual(r.target.y, 0, accuracy: 1e-6)

        var r2 = rig(yaw: 0, pitch: 0)
        r2.pan(dx: 0, dy: 100, viewportHeight: 669)   // drag down → model moves down → target up
        XCTAssertGreaterThan(r2.target.y, 0)
        XCTAssertEqual(r2.target.x, 0, accuracy: 1e-6)
    }

    func testPanMovesTheModelByTheSameAmountAsTheFingers() {
        // At the target's depth, one viewport-height of drag is one viewport-height of world.
        var r = rig(yaw: 0, pitch: 0)
        r.pan(dx: 0, dy: 669, viewportHeight: 669)
        let visibleHeight = 2 * r.distance * tan(r.fovYRadians / 2)
        XCTAssertEqual(r.target.y, visibleHeight, accuracy: 1e-5)
    }

    /// Rotation has no limit: keep dragging and the camera keeps going around and over the top,
    /// always with a valid, right-handed frame.
    func testRotationIsUnlimitedInBothDirections() {
        var r = rig()
        for step in 0..<2000 {
            r.rotate(dx: step % 7 == 0 ? -9 : 6, dy: step % 2 == 0 ? 11 : 4)
            XCTAssertTrue(r.yaw.isFinite && r.pitch.isFinite)
            XCTAssertEqual(simd_length(r.right), 1, accuracy: 1e-4)
            XCTAssertEqual(simd_length(r.up), 1, accuracy: 1e-4)
            XCTAssertEqual(simd_dot(r.right, r.forward), 0, accuracy: 1e-4)
        }
        var v = rig(yaw: 0, pitch: 0)
        v.rotate(dx: 0, dy: 100_000)
        XCTAssertLessThan(abs(v.pitch), .pi + 1e-4, "angles wrap instead of growing forever")
    }

    func testPitchGoesOverTheTopAndTheViewFlipsUpsideDown() {
        var r = rig(yaw: 0, pitch: 0)
        r.rotate(dx: 0, dy: Float.pi / 2 * 1.5 / CameraRig.rotateSensitivity)   // 135°
        XCTAssertLessThan(r.up.y, 0, "past the pole the camera is upside down")
        XCTAssertEqual(r.right.x, 1, accuracy: 1e-5, "and the screen's right direction did not jump")
    }

    func testZoomIsClamped() {
        var r = rig()
        r.zoom(scale: 1_000_000)
        XCTAssertEqual(r.distance, CameraRig.distanceRange.lowerBound, accuracy: 1e-6)
        r.zoom(scale: 0.000_001)
        XCTAssertEqual(r.distance, CameraRig.distanceRange.upperBound, accuracy: 1e-6)
    }

    // MARK: Where and how the fold lands (camera space)

    private let aspect: Float = 951 / 669
    private let orientations: [(yaw: Float, pitch: Float)] = [(0, 0), (0.66, 0.45), (-1.1, 0.2), (2.4, -0.6), (0.3, 1.2)]

    /// A flat sheet facing the camera, centered on the rig's target: x runs along the screen's
    /// right direction, y along its up direction.
    private func screenFacingSheet(_ r: CameraRig, halfWidth: Float = 0.05, halfHeight: Float = 0.03) -> RenderMesh {
        let n = -r.forward
        func corner(_ x: Float, _ y: Float) -> SIMD3<Float> { r.target + r.right * x + r.up * y }
        return RenderMesh(
            positions: [corner(-halfWidth, -halfHeight), corner(halfWidth, -halfHeight),
                        corner(halfWidth, halfHeight), corner(-halfWidth, halfHeight)],
            normals: Array(repeating: n, count: 4),
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    func testFoldFrameIsAValidHingeForAnyViewAndCreasePosition() {
        for o in orientations {
            for fraction: Float in [0.5, 0.3, 0.75] {
                for axis in [ScreenCrease.Axis.vertical, .horizontal] {
                    let r = rig(yaw: o.yaw, pitch: o.pitch, target: SIMD3<Float>(0.02, -0.01, 0.03))
                    let f = r.foldFrame(crease: ScreenCrease(axis: axis, fraction: fraction), aspect: aspect)
                    XCTAssertEqual(simd_length(f.axis), 1, accuracy: 1e-4)
                    XCTAssertEqual(simd_length(f.normal), 1, accuracy: 1e-4)
                    XCTAssertEqual(simd_dot(f.axis, f.normal), 0, accuracy: 1e-4, "the hinge lies in the cut plane")
                    // The cut plane contains the camera: that is what makes the cut line up with the
                    // crease line on screen.
                    XCTAssertEqual(simd_dot(f.normal, r.position - f.pivot), 0, accuracy: 1e-4)
                }
            }
        }
    }

    func testCenteredCreaseFoldsAtTheTargetAndAlignsWithTheScreen() {
        for o in orientations {
            let r = rig(yaw: o.yaw, pitch: o.pitch, target: SIMD3<Float>(0.02, -0.01, 0.03))
            let f = r.foldFrame(crease: .centeredVertical, aspect: aspect)
            XCTAssertLessThan(simd_distance(f.pivot, r.target), 1e-5, "the hinge passes through what's under the crease")
            XCTAssertLessThan(simd_distance(f.axis, r.up), 1e-4, "a vertical crease hinges about screen-vertical")
            XCTAssertLessThan(simd_distance(f.normal, r.right), 1e-4, "the cut is perpendicular to screen-right")
        }
    }

    /// The reported complaint: the fold used to stay locked to the block's own axis while the view
    /// rotated. The cut plane must turn with the view.
    func testRotatingTheViewTurnsTheFoldPlane() {
        let front = rig(yaw: 0, pitch: 0).foldFrame(crease: .centeredVertical, aspect: aspect)
        let side = rig(yaw: .pi / 2, pitch: 0).foldFrame(crease: .centeredVertical, aspect: aspect)
        XCTAssertLessThan(simd_distance(front.normal, SIMD3<Float>(1, 0, 0)), 1e-4)
        XCTAssertLessThan(simd_distance(side.normal, SIMD3<Float>(0, 0, -1)), 1e-4)
        XCTAssertLessThan(abs(simd_dot(front.normal, side.normal)), 1e-4, "quarter turn → cut plane a quarter turn")
    }

    /// The reported complaint: panning the block must move where it folds.
    func testPanningMovesTheFoldWithTheBlock() {
        var r = rig(yaw: 0.66, pitch: 0.45)
        r.pan(dx: -80, dy: 30, viewportHeight: 669)
        let f = r.foldFrame(crease: .centeredVertical, aspect: aspect)
        XCTAssertLessThan(simd_distance(f.pivot, r.target), 1e-5)
        XCTAssertGreaterThan(simd_length(r.target), 0.01)
    }

    func testOffCenterCreaseHingesAwayFromTheTarget() {
        let r = rig(yaw: 0, pitch: 0)
        let f = r.foldFrame(crease: ScreenCrease(axis: .vertical, fraction: 0.75), aspect: aspect)
        let expected = 0.5 * r.distance * tan(r.fovYRadians / 2) * aspect
        XCTAssertEqual(f.pivot.x, expected, accuracy: 1e-4)
    }

    /// Both halves swing toward the viewer, about the screen-vertical hinge.
    func testVerticalCreaseSwingsBothHalvesTowardTheViewer() {
        for o in orientations {
            let r = rig(yaw: o.yaw, pitch: o.pitch)
            let frame = r.foldFrame(crease: .centeredVertical, aspect: aspect)
            let bent = BendDeformer.deform(screenFacingSheet(r), bendAngleRadians: 60 * .pi / 180, frame: frame)
            let byRight = bent.positions.map { simd_dot($0 - r.target, r.right) }
            let byDepth = bent.positions.map { simd_dot($0 - r.target, r.forward) }
            let byUp = bent.positions.map { simd_dot($0 - r.target, r.up) }
            XCTAssertLessThan(byDepth.min() ?? 0, -0.02, "the ends come toward the camera")
            XCTAssertLessThan(byDepth.max() ?? 1, 1e-4, "nothing swings away from the viewer")
            XCTAssertEqual(byRight.max() ?? 0, -(byRight.min() ?? 0), accuracy: 1e-4, "both halves swing equally")
            XCTAssertLessThan(byRight.max() ?? 1, 0.05 * cos(.pi / 6) + 0.003)
            XCTAssertEqual(byUp.max() ?? 0, 0.03, accuracy: 1e-4, "the hinge is vertical: heights are unchanged")
            XCTAssertEqual(byUp.min() ?? 0, -0.03, accuracy: 1e-4)
        }
    }

    func testHorizontalCreaseSwingsBothHalvesTowardTheViewer() {
        for o in orientations {
            let r = rig(yaw: o.yaw, pitch: o.pitch)
            let frame = r.foldFrame(crease: ScreenCrease(axis: .horizontal, fraction: 0.5), aspect: aspect)
            let bent = BendDeformer.deform(screenFacingSheet(r), bendAngleRadians: 60 * .pi / 180, frame: frame)
            let byUp = bent.positions.map { simd_dot($0 - r.target, r.up) }
            let byRight = bent.positions.map { simd_dot($0 - r.target, r.right) }
            let byDepth = bent.positions.map { simd_dot($0 - r.target, r.forward) }
            XCTAssertLessThan(byDepth.min() ?? 0, -0.012)
            XCTAssertLessThan(byDepth.max() ?? 1, 1e-4)
            XCTAssertEqual(byUp.max() ?? 0, -(byUp.min() ?? 0), accuracy: 1e-4)
            XCTAssertEqual(byRight.max() ?? 0, 0.05, accuracy: 1e-4, "the hinge is horizontal: widths are unchanged")
        }
    }

    /// The reported complaint: material used to poke out of the back of the fold. Whatever the view,
    /// no point may end up deeper (farther from the viewer) than the deepest point it started at.
    func testNothingPushesOutTheBackFromAnyView() {
        let block = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)
        for o in orientations {
            let r = rig(yaw: o.yaw, pitch: o.pitch)
            let frame = r.foldFrame(crease: .centeredVertical, aspect: aspect)
            let deepest = block.positions.map { simd_dot($0 - r.position, r.forward) }.max() ?? 0
            for degrees in [10.0, 45.0, 90.0, 135.0, 180.0] {
                let bent = BendDeformer.deform(block, bendAngleRadians: degrees * .pi / 180, frame: frame)
                let bentDeepest = bent.positions.map { simd_dot($0 - r.position, r.forward) }.max() ?? 0
                XCTAssertLessThanOrEqual(bentDeepest, deepest + 1e-4, "yaw \(o.yaw) pitch \(o.pitch) bend \(degrees)°")
                XCTAssertTrue(bent.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            }
        }
    }

    func testFrameCloseness() {
        let f = rig().foldFrame(crease: .centeredVertical, aspect: aspect)
        XCTAssertTrue(f.isClose(to: f))
        var moved = f; moved.pivot.x += 0.01
        XCTAssertFalse(f.isClose(to: moved))
        let turned = rig(yaw: 0.68).foldFrame(crease: .centeredVertical, aspect: aspect)
        XCTAssertFalse(f.isClose(to: turned))
    }
}

final class HingeMappingTests: XCTestCase {
    /// The reported complaint: the device reports 180° when flat, which used to read as a 90° fold.
    func testFullyOpenHingeIsFlat() {
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: .pi), 0, accuracy: 1e-12)
    }

    func testFiveDegreesOffFlatIsAFiveDegreeBend() {
        let bend = HingeInputManager.bend(fromHingeRadians: 175 * .pi / 180)
        XCTAssertEqual(bend * 180 / .pi, 5, accuracy: 1e-9)
    }

    func testBendGrowsOneToOneAsTheHingeCloses() {
        for hingeDegrees in stride(from: 175.0, through: 5.0, by: -10.0) {
            let bend = HingeInputManager.bend(fromHingeRadians: hingeDegrees * .pi / 180) * 180 / .pi
            XCTAssertEqual(bend, 180 - hingeDegrees, accuracy: 1e-9)
        }
    }

    func testClosedHingeIsAFullFold() {
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: 0), .pi, accuracy: 1e-12)
    }

    func testOutOfRangeAndInvalidReadingsAreSafe() {
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: 4), 0)          // past fully open
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: -1), .pi)       // below closed
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: .nan), 0)
        XCTAssertEqual(HingeInputManager.bend(fromHingeRadians: .infinity), 0)
    }
}

final class ViewSnapTests: XCTestCase {
    private func rig(yaw: Float, pitch: Float) -> CameraRig {
        CameraRig(target: .zero, yaw: yaw, pitch: pitch, distance: 0.3)
    }

    /// Snapping must land exactly on the face: the camera on that face's normal, looking at it.
    func testEveryFaceSnapsExactlyFromAnyStartingView() {
        for start in [(0.66, 0.45), (-2.5, 1.2), (3.0, 2.5), (5.9, -3.0), (0.0, 0.0)] as [(Float, Float)] {
            for face in ViewFace.allCases {
                var r = rig(yaw: start.0, pitch: start.1)
                let target = r.snapAngles(to: face)
                r.yaw = target.yaw; r.pitch = target.pitch
                XCTAssertLessThan(simd_distance(r.offsetDirection, face.normal), 1e-5, "\(face) from \(start)")
                if face != .top && face != .bottom {
                    XCTAssertEqual(r.up.y, 1, accuracy: 1e-5, "\(face) is upright")
                }
            }
        }
    }

    func testSnapTakesTheShortWayRound() {
        let r = rig(yaw: 6.0, pitch: 0)      // just under a full turn
        let target = r.snapAngles(to: .front)
        XCTAssertLessThan(abs(target.yaw - 6.0), .pi)
        let back = rig(yaw: -3.0, pitch: 0).snapAngles(to: .back)
        XCTAssertLessThan(abs(back.yaw + 3.0), .pi)
    }

    func testCubeHitTest() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertTrue(ViewCubeView.contains(square, CGPoint(x: 5, y: 5)))
        XCTAssertFalse(ViewCubeView.contains(square, CGPoint(x: 15, y: 5)))
        XCTAssertFalse(ViewCubeView.contains(square, CGPoint(x: 5, y: -1)))
    }
}
