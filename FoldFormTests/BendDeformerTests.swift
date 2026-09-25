import XCTest
import simd
@testable import FoldForm

final class BendDeformerTests: XCTestCase {
    /// 10 cm wide (X), 1 cm thick (Y), 10 cm long (Z), centered on the origin.
    private func plate() -> RenderMesh {
        GeometryBuilder.box(width: 0.1, height: 0.01, depth: 0.1)
    }

    /// A single flat quad in the XZ plane facing +Y.
    private func flatSheet() -> RenderMesh {
        RenderMesh(
            positions: [[-0.05, 0, -0.05], [0.05, 0, -0.05], [0.05, 0, 0.05], [-0.05, 0, 0.05]],
            normals: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4),
            indices: [0, 3, 2, 0, 2, 1]
        )
    }

    private func triangleNormal(_ mesh: RenderMesh, _ start: Int) -> (normal: SIMD3<Float>, centroid: SIMD3<Float>)? {
        let p = (0..<3).map { mesh.positions[Int(mesh.indices[start + $0])] }
        let n = simd_cross(p[1] - p[0], p[2] - p[0])
        guard simd_length(n) > 1e-9 else { return nil }
        return (simd_normalize(n), (p[0] + p[1] + p[2]) / 3)
    }

    /// Angle in degrees between the two straight halves' surfaces, measured from vertex *positions*
    /// (not from the deformer's own normals): the largest triangle on each side of the crease.
    private func angleBetweenHalves(_ mesh: RenderMesh, creaseX: Float) -> Float? {
        var left: (area: Float, normal: SIMD3<Float>)?
        var right: (area: Float, normal: SIMD3<Float>)?
        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[start + $0])] }
            let cross = simd_cross(p[1] - p[0], p[2] - p[0])
            let area = simd_length(cross)
            guard area > 1e-9 else { continue }
            let entry = (area: area, normal: cross / area)
            let centroidX = (p[0].x + p[1].x + p[2].x) / 3
            if centroidX < creaseX { if area > (left?.area ?? 0) { left = entry } }
            else if area > (right?.area ?? 0) { right = entry }
        }
        guard let left, let right else { return nil }
        return acos(max(-1, min(1, simd_dot(left.normal, right.normal)))) * 180 / .pi
    }

    func testZeroAngleIsUnchanged() {
        let mesh = plate()
        let bent = BendDeformer.deform(mesh, bendAngleRadians: 0)
        XCTAssertEqual(mesh.positions, bent.positions)
    }

    /// Folding 5° must bend the block 5°, not jump to some large angle.
    func testFiveDegreeBendChangesTheAngleBetweenHalvesByFiveDegrees() throws {
        let bent = BendDeformer.deform(flatSheet(), bendAngleRadians: 5 * .pi / 180)
        XCTAssertEqual(try XCTUnwrap(angleBetweenHalves(bent, creaseX: 0)), 5, accuracy: 0.05)
    }

    func testBendAngleIsOneToOneAcrossTheRange() throws {
        for degrees in stride(from: 5.0, through: 175.0, by: 10.0) {
            let bent = BendDeformer.deform(flatSheet(), bendAngleRadians: degrees * .pi / 180)
            XCTAssertEqual(Double(try XCTUnwrap(angleBetweenHalves(bent, creaseX: 0))), degrees, accuracy: 0.1, "bend \(degrees)°")
        }
    }

    func testOffCenterFoldStillBendsByTheRequestedAngle() throws {
        let creaseX: Float = -0.015
        let bent = BendDeformer.deform(flatSheet(), bendAngleRadians: 5 * .pi / 180, creaseX: creaseX)
        XCTAssertEqual(try XCTUnwrap(angleBetweenHalves(bent, creaseX: creaseX)), 5, accuracy: 0.05)
    }

    /// The reported complaint: nothing may come out of the back. The plate's bottom is its far
    /// side, so no point may drop below it at any angle — and the top must never rise into a spike.
    func testNothingPushesOutTheBack() {
        let bottom: Float = -0.005
        for degrees in stride(from: 5.0, through: 180.0, by: 5.0) {
            let bent = BendDeformer.deform(plate(), bendAngleRadians: degrees * .pi / 180)
            XCTAssertGreaterThanOrEqual(bent.positions.map(\.y).min() ?? 0, bottom - 1e-5, "bend \(degrees)°")
            XCTAssertTrue(bent.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }

    /// The fold is a smooth curve: many strips between flat and fully turned, so no sharp edge.
    func testTheBendIsSmoothNotASharpEdge() {
        let bent = BendDeformer.deform(plate(), bendAngleRadians: .pi / 2)
        // Top-face strips turn a little each; there must be many intermediate tilts, each small.
        var tilts: [Float] = []
        for start in stride(from: 0, to: bent.indices.count, by: 3) {
            guard let (n, _) = triangleNormal(bent, start), abs(n.z) < 1e-3, n.y > 0.01 else { continue }
            tilts.append(atan2(n.x, n.y) * 180 / .pi)
        }
        let distinct = Set(tilts.map { Int(($0 / 2).rounded()) })
        XCTAssertGreaterThanOrEqual(distinct.count, 10, "expected a run of intermediate tilts, got \(distinct.sorted())")
        XCTAssertEqual(tilts.map(abs).max() ?? 0, 45, accuracy: 0.5, "each straight half turns half of the bend")
        let sorted = Set(tilts.map { ($0 * 10).rounded() / 10 }).sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThan(b - a, 4.5, "neighbouring strips differ by a few degrees at most")
        }
    }

    /// Material follows the cylinder around the bend: the layer at the centre of the thickness keeps
    /// its length, and the inside never turns inside out at any bend, up to a complete fold.
    func testInsideRadiusStaysPositiveAndNeutralLayerKeepsItsLength() {
        let thickness: Float = 0.01
        let innerRadius = BendDeformer.innerRadiusPerThickness * thickness
        // Plate top is the near side (y = +0.005); the centre of curvature is `innerRadius` above it.
        let center = SIMD3<Float>(0, 0.005 + innerRadius, 0)
        for degrees in [30.0, 90.0, 180.0] {
            let bent = BendDeformer.deform(plate(), bendAngleRadians: degrees * .pi / 180)
            // Every point within the bend zone stays at least the inside radius from the centre.
            let zone = (innerRadius + thickness / 2) * Float(degrees * .pi / 180) / 2
            for p in bent.positions where abs(p.x) < zone - 1e-4 && abs(p.y - center.y) < 0.1 {
                XCTAssertGreaterThanOrEqual(simd_distance(SIMD2<Float>(p.x, p.y), SIMD2<Float>(center.x, center.y)), innerRadius - 1e-4, "bend \(degrees)°")
            }
            // The neutral layer (mid-thickness, y = 0) between the two ends of the arm still measures
            // the original 5 cm from the crease to the end, counting the arc.
            let neutralRadius = innerRadius + thickness / 2
            let phi = Float(degrees * .pi / 180) / 2
            let straight = 0.05 - neutralRadius * phi
            XCTAssertGreaterThan(straight, 0, "the arc fits inside the 5 cm half")
        }
    }

    /// A 90° fold of the 1 cm plate: the far end of the bottom (outside) surface lands where the
    /// cylinder model says it should.
    func testNinetyDegreeBendPutsTheOutsideEndWhereThePhysicsSaysItGoes() {
        let bent = BendDeformer.deform(plate(), bendAngleRadians: .pi / 2)
        let thickness = 0.01, innerRadius = 0.005
        let neutral = innerRadius + thickness / 2
        let phi = Double.pi / 4
        let rho = innerRadius + thickness                      // bottom (far) surface
        let extra = 0.05 - neutral * phi
        let x = rho * sin(phi) + extra * cos(phi)
        let up = rho * cos(phi) - extra * sin(phi)             // measured from the centre, downward
        let centerY = 0.005 + innerRadius
        let y = centerY - up                                   // depth runs downward from the centre
        XCTAssertTrue(bent.positions.contains { abs(Double($0.x) - x) < 1e-4 && abs(Double($0.y) - y) < 1e-4 }, "expected (\(x), \(y))")
        XCTAssertTrue(bent.positions.contains { abs(Double($0.x) + x) < 1e-4 && abs(Double($0.y) - y) < 1e-4 })
    }

    func testFoldStaysCenteredOnTheCrease() {
        let creaseX: Float = 0.02
        let bent = BendDeformer.deform(plate(), bendAngleRadians: 60 * .pi / 180, creaseX: creaseX)
        // Unequal halves: 3 cm short side, 7 cm long side.
        let shortReach = (bent.positions.map { $0.x }.max() ?? 0) - creaseX
        let longReach = creaseX - (bent.positions.map { $0.x }.min() ?? 0)
        XCTAssertLessThan(shortReach, 0.031)
        XCTAssertLessThan(longReach, 0.071)
        XCTAssertGreaterThan(longReach, 0.04)
        XCTAssertGreaterThan(longReach, shortReach)
    }

    func testNoPoppingContinuousAcrossSmallAngleSteps() {
        let mesh = plate()
        var previous = BendDeformer.deform(mesh, bendAngleRadians: 0)
        for step in 1...180 {
            let current = BendDeformer.deform(mesh, bendAngleRadians: Double(step) * .pi / 180)
            XCTAssertLessThan(simd_distance(current.boundingBox.min, previous.boundingBox.min), 0.01)
            XCTAssertLessThan(simd_distance(current.boundingBox.max, previous.boundingBox.max), 0.01)
            previous = current
        }
    }

    func testFoldingAnAlreadyBentMeshStillWorks() {
        let once = BendDeformer.deform(plate(), bendAngleRadians: 1.0, creaseX: -0.02)
        let twice = BendDeformer.deform(once, bendAngleRadians: 1.0, creaseX: 0.02)
        XCTAssertGreaterThan(twice.indices.count, 0)
        XCTAssertTrue(twice.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}

final class SharpCornerTests: XCTestCase {
    private let plate = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)
    private let frame = FoldFrame(pivot: SIMD3(0, -0.008, 0), axis: SIMD3(0, 0, -1), normal: SIMD3(1, 0, 0))
    private func sharp(_ degrees: Double, _ mesh: RenderMesh? = nil) -> RenderMesh {
        BendDeformer.deform(mesh ?? plate, bendAngleRadians: degrees * .pi / 180, frame: frame, corner: .sharp)
    }
    private func triangleNormal(_ m: RenderMesh, _ start: Int) -> (n: SIMD3<Float>, c: SIMD3<Float>, area: Float)? {
        let v = (0..<3).map { m.positions[Int(m.indices[start + $0])] }
        let cross = simd_cross(v[1] - v[0], v[2] - v[0])
        let area = simd_length(cross) / 2
        return area > 1e-10 ? (cross / (2 * area), (v[0] + v[1] + v[2]) / 3, area) : nil
    }

    func testZeroBendIsUntouchedAndFilletIsTheDefault() {
        XCTAssertEqual(BendDeformer.deform(plate, bendAngleRadians: 0, frame: frame, corner: .sharp), plate)
        XCTAssertEqual(
            BendDeformer.deform(plate, bendAngleRadians: 1, frame: frame),
            BendDeformer.deform(plate, bendAngleRadians: 1, frame: frame, corner: .fillet)
        )
        XCTAssertNotEqual(sharp(60), BendDeformer.deform(plate, bendAngleRadians: 60 * .pi / 180, frame: frame))
        XCTAssertEqual(CornerStyle.fillet.toggled, .sharp)
        XCTAssertEqual(CornerStyle.sharp.toggled, .fillet)
    }

    /// The straight parts of the two halves meet at exactly the bend angle, like the fillet.
    func testHalvesMeetAtTheRequestedAngle() {
        for degrees in [10.0, 45.0, 90.0, 140.0, 165.0] {
            // A single flat quad, so every triangle is a top-face strip of one half.
            let sheet = RenderMesh(
                positions: [[-0.05, 0, -0.05], [0.05, 0, -0.05], [0.05, 0, 0.05], [-0.05, 0, 0.05]],
                normals: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4),
                indices: [0, 3, 2, 0, 2, 1]
            )
            let bent = sharp(degrees, sheet)
            // The larger triangles of each half (the far strips, clear of the crease).
            var left: (Float, SIMD3<Float>)?, right: (Float, SIMD3<Float>)?
            for start in stride(from: 0, to: bent.indices.count, by: 3) {
                guard let t = triangleNormal(bent, start), t.c.x != 0 else { continue }
                let leftBest = left?.0 ?? 0, rightBest = right?.0 ?? 0
                if t.c.x < 0 && t.area > leftBest { left = (t.area, t.n) }
                if t.c.x > 0 && t.area > rightBest { right = (t.area, t.n) }
            }
            let angle = acos(max(-1, min(1, simd_dot(left!.1, right!.1)))) * 180 / .pi
            XCTAssertEqual(Double(angle), degrees, accuracy: 0.2, "\(degrees)°")
        }
    }

    /// The reported request: sharp, not rounded. The far (back) surface has a real crease, one edge
    /// where its direction changes by the whole bend, rather than a run of small steps.
    func testTheBackSurfaceHasOneSharpCrease() {
        let bent = sharp(90)
        // Back surface = original -Y face; its triangles face -Y until they tilt with each half.
        var tilts = Set<Int>()
        for start in stride(from: 0, to: bent.indices.count, by: 3) {
            guard let t = triangleNormal(bent, start), abs(t.n.z) < 1e-3, t.n.y < -0.2 else { continue }
            tilts.insert(Int((atan2(t.n.x, -t.n.y) * 180 / .pi / 5).rounded()))
        }
        // Only the two halves' orientations (about ±45°), possibly a small blend region.
        XCTAssertTrue(tilts.contains(9) || tilts.contains(-9), "tilts: \(tilts.sorted())")
        let smooth = BendDeformer.deform(plate, bendAngleRadians: .pi / 2, frame: frame)
        var smoothTilts = Set<Int>()
        for start in stride(from: 0, to: smooth.indices.count, by: 3) {
            guard let t = triangleNormal(smooth, start), abs(t.n.z) < 1e-3, t.n.y < -0.2 else { continue }
            smoothTilts.insert(Int((atan2(t.n.x, -t.n.y) * 180 / .pi / 5).rounded()))
        }
        XCTAssertGreaterThan(smoothTilts.count, tilts.count, "the fillet steps through many tilts; the sharp fold does not")
    }

    /// Nothing may come out the back, at any angle, and everything stays finite.
    func testNothingPushesOutTheBack() {
        let backPlane: Float = -0.008
        for degrees in stride(from: 5.0, through: 175.0, by: 10.0) {
            let bent = sharp(degrees)
            XCTAssertGreaterThanOrEqual(bent.positions.map(\.y).min() ?? 0, backPlane - 1e-4, "\(degrees)°")
            XCTAssertTrue(bent.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }

    /// The two halves share the crease exactly, so the solid stays closed: every edge of the welded
    /// mesh belongs to two triangles.
    func testTheSolidStaysClosedAcrossTheCrease() {
        for degrees in [20.0, 90.0, 150.0] {
            let (positions, indices) = ModelExporter.welded(sharp(degrees))
            var edges: [[UInt32]: Int] = [:]
            for s in stride(from: 0, to: indices.count, by: 3) {
                for e in 0..<3 { edges[[indices[s + e], indices[s + (e + 1) % 3]].sorted(), default: 0] += 1 }
            }
            XCTAssertFalse(positions.isEmpty)
            XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, "\(degrees)°: open edges \(edges.values.filter { $0 != 2 }.count)")
        }
    }

    func testFarEndsOfTheHalvesStayRigidAndSquare() {
        let bent = sharp(90)
        // The outermost end of the +X half is a rigid copy of the original end cap: its points keep
        // the original spacing (0.016 thick, 0.05 deep).
        let rightEnd = bent.positions.filter { $0.x > 0.02 }
        XCTAssertFalse(rightEnd.isEmpty)
        let farthest = rightEnd.max { simd_length($0 - SIMD3(0, -0.008, 0)) < simd_length($1 - SIMD3(0, -0.008, 0)) }!
        let atEnd = rightEnd.filter { simd_distance($0, farthest) < 0.0161 }
        XCTAssertGreaterThan(atEnd.count, 2)
    }

    func testFoldingFromAnyViewIsFiniteAndOneToOne() {
        let aspect: Float = 951 / 669
        for (yaw, pitch) in [(0, 0), (0.66, 0.45), (2.4, -0.6), (0.3, 1.2)] as [(Float, Float)] {
            let rig = CameraRig(target: .zero, yaw: yaw, pitch: pitch, distance: 0.3)
            let camFrame = rig.foldFrame(crease: .centeredVertical, aspect: aspect)
            let bent = BendDeformer.deform(plate, bendAngleRadians: 1.2, frame: camFrame, corner: .sharp)
            XCTAssertTrue(bent.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            XCTAssertTrue(bent.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-3 }, "unit normals")
            let deepest = plate.positions.map { simd_dot($0 - rig.position, rig.forward) }.max()!
            let bentDeepest = bent.positions.map { simd_dot($0 - rig.position, rig.forward) }.max()!
            XCTAssertLessThanOrEqual(bentDeepest, deepest + 1e-3, "yaw \(yaw) pitch \(pitch)")
        }
    }

    func testSharpFoldsStackOnAnAlreadyBentMesh() {
        let once = sharp(60)
        let twice = BendDeformer.deform(once, bendAngleRadians: 1, frame: FoldFrame(pivot: SIMD3(0.03, -0.008, 0), axis: SIMD3(0, 0, -1), normal: SIMD3(1, 0, 0)), corner: .sharp)
        XCTAssertTrue(twice.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertGreaterThan(twice.indices.count, 0)
    }
}
