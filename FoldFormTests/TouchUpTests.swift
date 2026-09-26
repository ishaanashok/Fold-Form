import XCTest
import simd
@testable import FoldForm

private struct NoAdvisor: TouchUpAdvisor {
    func decide(summary: String, options: [String]) async -> AdvisorDecision? { nil }
}

private struct VetoAdvisor: TouchUpAdvisor {
    func decide(summary: String, options: [String]) async -> AdvisorDecision? { AdvisorDecision(choice: -1, reason: "deliberate") }
}

private func lines(_ points: [SIMD2<Float>]) -> [SketchShape] {
    points.indices.map { .line(points[$0], points[($0 + 1) % points.count]) }
}

final class ShapeAnalysisTests: XCTestCase {
    func testBumpOnARectangleIsRemovedAndReadAsARectangle() {
        let drawn: [SIMD2<Float>] = [[0, 0], [0.02, 0], [0.03, 0.0012], [0.04, 0], [0.06, 0], [0.0602, 0.03], [0, 0.03]]
        let analysis = ShapeAnalysis.analyze(drawn)
        XCTAssertEqual(analysis.cleaned.count, 4)
        XCTAssertEqual(analysis.bumpsRemoved, 3)
        XCTAssertEqual(analysis.bestCandidate?.kind, .rectangle)
        let corners = analysis.bestCandidate!.points
        for angle in ShapeAnalysis.interiorAngles(corners) { XCTAssertEqual(angle, 90, accuracy: 0.01) }
        let sides = ShapeAnalysis.sideLengths(corners)
        XCTAssertEqual(sides[0], sides[2], accuracy: 1e-5)
        XCTAssertEqual(sides[1], sides[3], accuracy: 1e-5)
    }

    func testWobblyThreeFourFiveTriangleIsARightTriangleByPythagoras() {
        let drawn: [SIMD2<Float>] = [[0, 0], [0.06, 0.001], [0.001, 0.041]]
        let best = ShapeAnalysis.analyze(drawn).bestCandidate
        XCTAssertEqual(best?.kind, .rightTriangle)
        let angles = ShapeAnalysis.interiorAngles(best!.points)
        XCTAssertEqual(angles.reduce(0, +), 180, accuracy: 0.01, "angle sum theorem")
        XCTAssertEqual(angles.max()!, 90, accuracy: 0.01)
    }

    func testNearlyEqualSidesGiveAnEquilateralTriangle() {
        let drawn: [SIMD2<Float>] = [[0, 0], [0.05, 0.001], [0.026, 0.044]]
        let best = ShapeAnalysis.analyze(drawn).bestCandidate
        XCTAssertEqual(best?.kind, .equilateralTriangle)
        for angle in ShapeAnalysis.interiorAngles(best!.points) { XCTAssertEqual(angle, 60, accuracy: 0.01) }
    }

    func testJitteredRoundLoopIsACircle() {
        let drawn = (0..<20).map { i -> SIMD2<Float> in
            let a = Float(i) / 20 * 2 * .pi
            let r: Float = 0.03 * (1 + (i % 2 == 0 ? 0.03 : -0.03))
            return SIMD2(cos(a), sin(a)) * r
        }
        let best = ShapeAnalysis.analyze(drawn).bestCandidate
        XCTAssertEqual(best?.kind, .circle)
        XCTAssertEqual(best?.circle?.radius ?? 0, 0.03, accuracy: 0.001)
    }

    func testAnIrregularPolygonHasNoReading() {
        let drawn: [SIMD2<Float>] = [[0, 0], [0.08, 0.005], [0.085, 0.02], [0.03, 0.06], [-0.01, 0.03]]
        let analysis = ShapeAnalysis.analyze(drawn)
        XCTAssertNil(analysis.bestCandidate)
        XCTAssertEqual(analysis.bumpsRemoved, 0)
    }
}

@MainActor
final class TouchUpEngineTests: XCTestCase {
    private func touchUp(_ points: [SIMD2<Float>], advisor: TouchUpAdvisor = NoAdvisor()) async -> TouchUpEngine.SketchResult {
        let shapes = lines(points)
        let segments = shapes.compactMap { s -> (SIMD2<Float>, SIMD2<Float>)? in
            if case .line(let a, let b) = s { return (a, b) } else { return nil }
        }
        return await TouchUpEngine(advisor: advisor).touchUp(shapes: shapes, segments: segments, tolerance: 0.001)
    }

    func testBumpySketchIsFixed() async {
        let result = await touchUp([[0, 0], [0.02, 0], [0.03, 0.0012], [0.04, 0], [0.06, 0], [0.06, 0.03], [0, 0.03]])
        XCTAssertTrue(result.outcome.changed)
        XCTAssertEqual(result.shapes?.count, 4)
        XCTAssertTrue(result.outcome.message.contains("rectangle"), result.outcome.message)
    }

    func testUnrecognisableCleanSketchSaysItCouldNotFigureItOut() async {
        let result = await touchUp([[0, 0], [0.08, 0.005], [0.085, 0.02], [0.03, 0.06], [-0.01, 0.03]])
        XCTAssertFalse(result.outcome.changed)
        XCTAssertEqual(result.outcome.message, "Wasn't able to figure out what was being created.")
    }

    func testTheModelCanVetoAReading() async {
        let result = await touchUp([[0, 0], [0.06, 0.001], [0.001, 0.041]], advisor: VetoAdvisor())
        XCTAssertFalse(result.outcome.changed)
        XCTAssertEqual(result.outcome.message, "Wasn't able to figure out what was being created.")
    }

    func testAlreadyExactShapeIsLeftAlone() async {
        let result = await touchUp([[0, 0], [0.06, 0], [0.06, 0.03], [0, 0.03]])
        XCTAssertFalse(result.outcome.changed)
        XCTAssertTrue(result.outcome.message.hasPrefix("Already clean"), result.outcome.message)
    }

    func testCleanBoxBodyNeedsNothingAndIsRecognised() async {
        let box = GeometryBuilder.box(width: 0.06, height: 0.01, depth: 0.03)
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: [(UUID(), box)])
        XCTAssertTrue(result.meshes.isEmpty)
        XCTAssertTrue(result.outcome.message.contains("box"), result.outcome.message)
    }
}

/// Bodies built the way the app builds them: extruded sketches, then cuts.
@MainActor
final class BodyTouchUpTests: XCTestCase {
    private let plane = SketchPlane(origin: SIMD3(0, 0.008, 0), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), n: SIMD3(0, 1, 0))
    private let wobbly: [SIMD2<Float>] = [[0, 0], [0.02, 0], [0.03, 0.0012], [0.04, 0], [0.06, 0], [0.06, 0.03], [0, 0.03]]

    private func thinTriangles(_ mesh: RenderMesh) -> Int {
        var count = 0
        for s in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[s])], b = mesh.positions[Int(mesh.indices[s + 1])], c = mesh.positions[Int(mesh.indices[s + 2])]
            let t = MeshTouchUp.Topology.smallestAngle(SIMD3(0, 1, 2), [a, b, c])
            if t < 8 { count += 1 }
        }
        return count
    }

    func testAnExtrudedBodyWithABumpyOutlineIsRebuiltAsARectangularSlab() async {
        let slab = SketchGeometry.slab(profile: wobbly, depth: 0.008, on: plane)
        let report = await TouchUpEngine(advisor: NoAdvisor()).touchUp(body: slab)
        XCTAssertNotNil(report.mesh)
        XCTAssertGreaterThan(report.findings.outlineBumps, 0)
        XCTAssertEqual(report.findings.outlineReadings.first, "rectangle")
        let profile = MeshTouchUp.prismProfile(of: report.mesh!)
        XCTAssertEqual(profile?.loops.first?.count, 4)
        XCTAssertEqual(profile?.height ?? 0, 0.008, accuracy: 1e-5)
        XCTAssertEqual(report.mesh!.solidProperties!.volume, 0.06 * 0.03 * 0.008, accuracy: 0.06 * 0.03 * 0.008 * 0.02)
    }

    func testACutBodyIsRepairedWithoutChangingItsShape() async throws {
        let model = AppModel()
        model.addViewportSolids([SketchGeometry.slab(profile: [[0, 0], [0.06, 0], [0.06, 0.03], [0, 0.03]], depth: 0.008, on: plane)])
        model.addViewportCuts([SketchGeometry.cutter(profile: [[0.01, 0.01], [0.03, 0.01], [0.03, 0.02], [0.01, 0.02]], depth: 0.004, on: plane)])
        let id = model.document.partStudio.orderedBodyIDs.last!
        let before = model.document.partStudio.body(id)!.mesh
        let report = await TouchUpEngine(advisor: NoAdvisor()).touchUp(body: before)
        let after = try XCTUnwrap(report.mesh, "a BSP cut leaves slivers to fix")
        XCTAssertGreaterThan(report.findings.meshFixes, 0)
        XCTAssertLessThanOrEqual(thinTriangles(after), thinTriangles(before))
        XCTAssertEqual(after.solidProperties!.volume, before.solidProperties!.volume, accuracy: before.solidProperties!.volume * 1e-3)
        let a = after.boundingBox, b = before.boundingBox
        XCTAssertEqual(simd_distance(a.min, b.min), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(a.max, b.max), 0, accuracy: 1e-5)
    }

    func testTouchUpAppliesToTheDocumentAndUndoes() async {
        let model = AppModel()
        let ids = model.addViewportSolids([SketchGeometry.slab(profile: wobbly, depth: 0.008, on: plane)])
        let before = model.snapshotDocument()
        let bodies = model.document.partStudio.orderedBodyIDs.compactMap { id in model.document.partStudio.body(id).map { (id, $0.mesh) } }
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        XCTAssertTrue(result.outcome.changed, result.outcome.message)
        model.applyTouchUp(result.meshes)
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, 2)
        let cleaned = model.document.partStudio.body(ids[0])!.mesh
        XCTAssertNotEqual(MeshTouchUp.prismProfile(of: cleaned)?.loops.first?.count, 7, "the bumpy outline is gone")
        model.restoreDocument(before)
        XCTAssertEqual(MeshTouchUp.prismProfile(of: model.document.partStudio.body(ids[0])!.mesh)?.loops.first?.count, 7)
    }

    func testABodyWithAThroughHoleKeepsItsHole() async {
        let hole = (0..<24).map { i -> SIMD2<Float> in let a = Float(i) / 24 * 2 * .pi; return SIMD2(cos(a), sin(a)) * 0.006 + SIMD2(0.03, 0.015) }
        let local = try! GeometryBuilder.prism(
            outer: [SIMD2<Double>(0, 0), SIMD2(0.0602, 0), SIMD2(0.06, 0.03), SIMD2(0, 0.0299)],
            holes: [hole.map { SIMD2<Double>(Double($0.x), Double($0.y)) }], height: 0.008, centered: false
        )
        let report = await TouchUpEngine(advisor: NoAdvisor()).touchUp(body: local)
        let mesh = report.mesh ?? local
        XCTAssertEqual(MeshTouchUp.prismProfile(of: mesh)?.loops.count, 2, "outline and hole")
        let expected = (0.06 * 0.03 - Double.pi * 0.006 * 0.006 * 0.99) * 0.008
        XCTAssertEqual(Double(mesh.solidProperties!.volume), expected, accuracy: expected * 0.03)
    }
}

final class MeshTouchUpTests: XCTestCase {
    /// A flat 5 x 5 grid in the XZ plane with one vertex pushed up.
    private func bumpyGrid(bump: Float) -> RenderMesh {
        let n = 5, step: Float = 0.01
        var mesh = RenderMesh.empty
        for z in 0..<n { for x in 0..<n {
            let raised = (x == 2 && z == 2) ? bump : 0
            mesh.positions.append(SIMD3(Float(x) * step, raised, Float(z) * step))
            mesh.normals.append(SIMD3(0, 1, 0))
        } }
        for z in 0..<(n - 1) { for x in 0..<(n - 1) {
            let a = UInt32(z * n + x), b = a + 1, c = a + UInt32(n), d = c + 1
            mesh.indices += [a, c, b, b, c, d]
        } }
        return mesh
    }

    func testASpikeIsFoundAndFlattened() {
        let mesh = bumpyGrid(bump: 0.002)
        XCTAssertEqual(MeshTouchUp.analyze(mesh).spikes, 1)
        let smoothed = MeshTouchUp.smoothed(mesh)
        for p in smoothed.positions { XCTAssertEqual(p.y, 0, accuracy: 1e-6) }
        XCTAssertEqual(MeshTouchUp.analyze(smoothed).spikes, 0)
        XCTAssertEqual(smoothed.indices.count, mesh.indices.count)
    }

    func testAFlatGridHasNothingToSmooth() {
        let flat = bumpyGrid(bump: 0)
        XCTAssertTrue(MeshTouchUp.analyze(flat).isClean)
        XCTAssertEqual(MeshTouchUp.smoothed(flat), flat)
    }

    func testBoxAndCylinderAreCleanAndRecognised() {
        let box = MeshTouchUp.analyze(GeometryBuilder.box(width: 0.06, height: 0.01, depth: 0.03))
        XCTAssertTrue(box.isClean)
        XCTAssertEqual(box.shapeGuess, "box")
        let cylinder = MeshTouchUp.analyze(GeometryBuilder.cylinder(radius: 0.01, height: 0.02))
        XCTAssertTrue(cylinder.isClean)
        XCTAssertEqual(cylinder.shapeGuess, "cylinder")
    }
}

private struct PlanAdvisor: TouchUpAdvisor {
    var plan: DesignPlan?
    func decide(summary: String, options: [String]) async -> AdvisorDecision? { nil }
    func plan(description: String) async -> DesignPlan? { plan }
}

private func group(_ members: [Int], role: String = "part", identical: Bool = true, mirrored: Bool = true, material: String = "") -> DesignPlan.Group {
    DesignPlan.Group(role: role, members: members, identicalSize: identical, mirrored: mirrored, alignEdges: true, evenlySpaced: members.count >= 3, softenCorners: false, material: material)
}

private func block(_ x: Float, _ y: Float, _ z: Float, at centre: SIMD3<Float>) -> RenderMesh {
    GeometryBuilder.box(width: Double(x), height: Double(y), depth: Double(z)).translated(by: centre)
}

private func size(_ mesh: RenderMesh) -> SIMD3<Float> { let b = mesh.boundingBox; return b.max - b.min }
private func centre(_ mesh: RenderMesh) -> SIMD3<Float> { let b = mesh.boundingBox; return (b.min + b.max) / 2 }

/// A table: a top plate with four legs underneath, drawn sloppily.
@MainActor
final class TableRegularisationTests: XCTestCase {
    private let topPlane = SketchPlane(origin: .zero, u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), n: SIMD3(0, 1, 0))
    private let legPlane = SketchPlane(origin: .zero, u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), n: SIMD3(0, -1, 0))

    private func table(legs: [[SIMD2<Float>]]) -> [(id: UUID, mesh: RenderMesh)] {
        var bodies: [(id: UUID, mesh: RenderMesh)] = [(UUID(), SketchGeometry.slab(profile: [[0, 0], [0.1, 0], [0.1, 0.06], [0, 0.06]], depth: 0.008, on: topPlane))]
        for (i, leg) in legs.enumerated() {
            bodies.append((UUID(), SketchGeometry.slab(profile: leg, depth: 0.03 + Float(i) * 0.001, on: legPlane)))
        }
        return bodies
    }

    private var sloppyLegs: [[SIMD2<Float>]] {
        [
            [[0.009, -0.009], [0.017, -0.0085], [0.0175, -0.0175], [0.0085, -0.0165]],
            [[0.082, -0.010], [0.0905, -0.0102], [0.0903, -0.0187], [0.0818, -0.0185]],
            [[0.0095, -0.0430], [0.0182, -0.0428], [0.0181, -0.0512], [0.0093, -0.0515]],
            [[0.0805, -0.0445], [0.0888, -0.0441], [0.0890, -0.0530], [0.0808, -0.0527]],
        ]
    }

    func testFourSloppyLegsBecomeIdenticalSymmetricRectangles() async {
        let bodies = table(legs: sloppyLegs)
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        XCTAssertTrue(result.outcome.changed, result.outcome.message)
        let legs = bodies.dropFirst().map { result.meshes[$0.id] ?? $0.mesh }
        for leg in legs {
            let profile = MeshTouchUp.prismProfile(of: leg)!
            XCTAssertEqual(profile.loops[0].count, 4, "a proper rectangle")
            for angle in ShapeAnalysis.interiorAngles(profile.loops[0]) { XCTAssertEqual(angle, 90, accuracy: 0.01) }
            XCTAssertEqual(size(leg).x, size(legs[0]).x, accuracy: 1e-5)
            XCTAssertEqual(size(leg).y, size(legs[0]).y, accuracy: 1e-5, "same length")
            XCTAssertEqual(size(leg).z, size(legs[0]).z, accuracy: 1e-5)
        }
        let middle = SIMD3<Float>(0.05, 0, -0.03)
        let dx = legs.map { abs(centre($0).x - middle.x) }, dz = legs.map { abs(centre($0).z - middle.z) }
        for value in dx { XCTAssertEqual(value, dx[0], accuracy: 1e-5) }
        for value in dz { XCTAssertEqual(value, dz[0], accuracy: 1e-5) }
        XCTAssertEqual(Set(legs.map { centre($0).x > middle.x }).count, 2)
        XCTAssertEqual(Set(legs.map { centre($0).z > middle.z }).count, 2)
        for leg in legs { XCTAssertEqual(leg.boundingBox.max.y, 0, accuracy: 1e-5, "still hanging from the top") }
    }

    func testLegsThatAlmostTouchTheEdgeAreSnappedFlush() async {
        let s: Float = 0.008
        func leg(_ x: Float, _ z: Float) -> [SIMD2<Float>] { [[x, z], [x + s, z], [x + s, z - s], [x, z - s]] }
        let bodies = table(legs: [leg(0.001, -0.001), leg(0.0905, -0.0012), leg(0.0011, -0.0512), leg(0.0908, -0.0508)])
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        let legs = bodies.dropFirst().map { result.meshes[$0.id] ?? $0.mesh }
        XCTAssertEqual((legs.map { $0.boundingBox.min.x }).min()!, 0, accuracy: 1e-5)
        XCTAssertEqual((legs.map { $0.boundingBox.max.x }).max()!, 0.1, accuracy: 1e-5)
    }

    func testAlreadyPerfectLegsAreNotTouched() async {
        let s: Float = 0.008
        func leg(_ x: Float, _ z: Float) -> [SIMD2<Float>] { [[x, z], [x + s, z], [x + s, z - s], [x, z - s]] }
        var bodies = [(UUID(), SketchGeometry.slab(profile: [[0, 0], [0.1, 0], [0.1, 0.06], [0, 0.06]], depth: 0.008, on: topPlane))]
        for (x, z) in [(0.01, -0.01), (0.082, -0.01), (0.01, -0.042), (0.082, -0.042)] as [(Float, Float)] {
            bodies.append((UUID(), SketchGeometry.slab(profile: leg(x, z), depth: 0.03, on: legPlane)))
        }
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        for leg in bodies.dropFirst() { XCTAssertNil(result.meshes[leg.0], result.outcome.message) }
    }

    func testTheTableIsFinishedWithRoundedTopRailsAndColour() async {
        let s: Float = 0.008
        func leg(_ x: Float, _ z: Float, _ size: Float) -> [SIMD2<Float>] { [[x, z], [x + size, z], [x + size, z - size], [x, z - size]] }
        let bodies = table(legs: [leg(0.012, -0.011, s), leg(0.0805, -0.0095, s * 1.1), leg(0.0115, -0.0435, s * 0.9), leg(0.0815, -0.0447, s)])
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        XCTAssertTrue(result.outcome.message.contains("Finished it"), result.outcome.message)
        XCTAssertFalse(result.outcome.message.lowercased().contains("table"), "nothing here is table-specific")

        let top = result.meshes[bodies[0].id]!
        XCTAssertGreaterThan(MeshTouchUp.prismProfile(of: top)!.loops[0].count, 4, "rounded corners")
        XCTAssertEqual(size(top).x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(size(top).z, 0.06, accuracy: 1e-4)

        XCTAssertEqual(result.additions.count, 4, "rails between the posts")
        for rail in result.additions.map(\.mesh) {
            let b = rail.boundingBox
            XCTAssertEqual(b.max.y, 0, accuracy: 1e-5)
            XCTAssertLessThan(b.max.y - b.min.y, 0.03)
        }
        XCTAssertNotNil(result.styles[bodies[0].id])
        for leg in bodies.dropFirst() { XCTAssertNotNil(result.styles[leg.id]) }
        XCTAssertNotEqual(result.styles[bodies[0].id]?.name, result.styles[bodies[1].id]?.name, "top and legs get different colours")
    }

    func testFinishingTwiceChangesNothingMore() async {
        let s: Float = 0.008
        func leg(_ x: Float, _ z: Float) -> [SIMD2<Float>] { [[x, z], [x + s, z], [x + s, z - s], [x, z - s]] }
        let bodies = table(legs: [leg(0.012, -0.011), leg(0.0805, -0.0095), leg(0.0115, -0.0435), leg(0.0815, -0.0447)])
        let first = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        var second = bodies.map { (id: $0.id, mesh: first.meshes[$0.id] ?? $0.mesh) }
        var styles = first.styles
        for addition in first.additions {
            let id = UUID()
            second.append((id: id, mesh: addition.mesh))
            if let style = addition.style { styles[id] = style }
        }
        let again = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: second, styles: styles)
        XCTAssertTrue(again.additions.isEmpty, "rails are not added twice")
        XCTAssertTrue(again.styles.isEmpty, "coloured parts keep their colour")
    }
}

/// The same machinery on things that are not tables.
@MainActor
final class OtherDesignTests: XCTestCase {
    func testABookcaseGetsIdenticalUprightsAndEvenShelves() async {
        // Two uprights and three shelves, all a little off.
        var bodies: [(id: UUID, mesh: RenderMesh)] = [
            (UUID(), block(0.010, 0.100, 0.03, at: [-0.045, 0.05, 0])),
            (UUID(), block(0.0115, 0.098, 0.03, at: [0.0448, 0.0492, 0])),
        ]
        for (thickness, y) in [(0.008, 0.02), (0.0095, 0.058), (0.007, 0.090)] as [(Float, Float)] {
            bodies.append((UUID(), block(0.079, thickness, 0.03, at: [0, y, 0])))
        }
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        XCTAssertFalse(result.outcome.message.lowercased().contains("table"), result.outcome.message)
        let meshes = bodies.map { result.meshes[$0.id] ?? $0.mesh }
        XCTAssertEqual(size(meshes[0]).x, size(meshes[1]).x, accuracy: 1e-5)
        XCTAssertEqual(size(meshes[0]).y, size(meshes[1]).y, accuracy: 1e-5)
        XCTAssertEqual(centre(meshes[0]).x + centre(meshes[1]).x, 2 * centre(meshes[2]).x, accuracy: 1e-5, "uprights mirror about the shelves")
        let shelves = meshes[2...]
        for shelf in shelves { XCTAssertEqual(size(shelf).y, size(meshes[2]).y, accuracy: 1e-5, "shelves match") }
        let ys = shelves.map { centre($0).y }.sorted()
        XCTAssertEqual(ys[1] - ys[0], ys[2] - ys[1], accuracy: 1e-5, "evenly spaced")
        XCTAssertTrue(result.additions.isEmpty, "no posts to brace")
    }

    func testAChairKeepsItsBackDifferentAndCentresIt() async {
        var bodies: [(id: UUID, mesh: RenderMesh)] = [(UUID(), block(0.06, 0.008, 0.06, at: [0, 0, 0]))]   // seat, y from -0.004 to 0.004
        for (x, z, w) in [(-0.025, -0.025, 0.007), (0.0265, -0.0245, 0.0085), (-0.0245, 0.026, 0.008), (0.0255, 0.0255, 0.0075)] as [(Float, Float, Float)] {
            bodies.append((UUID(), block(w, 0.03, w, at: [x, -0.004 - 0.015, z])))
        }
        bodies.append((UUID(), block(0.052, 0.04, 0.006, at: [0.004, 0.004 + 0.02, -0.027])))   // back, off to one side
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        XCTAssertFalse(result.outcome.message.lowercased().contains("table"), result.outcome.message)
        let meshes = bodies.map { result.meshes[$0.id] ?? $0.mesh }
        for leg in meshes[1...4] { XCTAssertEqual(size(leg).x, size(meshes[1]).x, accuracy: 1e-5) }
        XCTAssertEqual(centre(meshes[5]).x, centre(meshes[0]).x, accuracy: 1e-5, "the back is centred on the seat")
        XCTAssertEqual(size(meshes[5]).x, 0.052, accuracy: 1e-5, "the back is not made into a leg")
        XCTAssertEqual(size(meshes[5]).y, 0.04, accuracy: 1e-5)
    }

    func testRoundWheelsBecomeIdenticalAndMirrored() async {
        var bodies: [(id: UUID, mesh: RenderMesh)] = [(UUID(), block(0.1, 0.02, 0.03, at: [0, 0, 0]))]   // chassis
        // Wheels on the front and back faces, axes along z, different radii.
        for (x, z, r) in [(-0.035, 0.015 + 0.003, 0.010), (0.036, 0.015 + 0.003, 0.0115), (-0.034, -0.015 - 0.003, 0.0105), (0.035, -0.015 - 0.003, 0.0095)] as [(Float, Float, Float)] {
            bodies.append((UUID(), GeometryBuilder.cylinder(radius: Double(r), height: 0.006).translated(by: [x, -0.012, z])))
        }
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: bodies)
        let wheels = bodies.dropFirst().map { result.meshes[$0.id] ?? $0.mesh }
        for wheel in wheels {
            XCTAssertEqual(size(wheel).x, size(wheels[0]).x, accuracy: 1e-5, "same diameter")
            XCTAssertEqual(size(wheel).y, size(wheels[0]).y, accuracy: 1e-5)
        }
        let xs = wheels.map { abs(centre($0).x) }
        for x in xs { XCTAssertEqual(x, xs[0], accuracy: 1e-5, "mirrored about the middle") }
    }

    func testASingleUnrelatedPartHasNothingToRelateTo() async {
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: [(UUID(), GeometryBuilder.box(width: 0.05, height: 0.01, depth: 0.03))])
        XCTAssertTrue(result.additions.isEmpty)
        XCTAssertTrue(result.styles.isEmpty)
    }
}

@MainActor
final class DesignIntentTests: XCTestCase {
    func testAModelPlanCanLeaveAPartOutOfTheGroupAndChooseColours() async {
        var bodies: [(id: UUID, mesh: RenderMesh)] = [(UUID(), block(0.1, 0.008, 0.06, at: [0.05, 0.004, -0.03]))]
        for (x, z, s) in [(0.012, -0.012, Float(0.008)), (0.0885, -0.0115, 0.0088), (0.0505, -0.05, 0.0072)] as [(Float, Float, Float)] {
            bodies.append((UUID(), block(s, 0.03, s, at: [x, -0.015, z])))
        }
        bodies.append((UUID(), block(0.03, 0.03, 0.03, at: [0.05, -0.015, -0.03])))   // an odd block in the middle
        let plan = DesignPlan(kind: "stool", groups: [
            group([0], role: "seat", material: "pine"),
            group([1, 2, 3], role: "leg", material: "black"),
        ], reason: "test")
        let result = await TouchUpEngine(advisor: PlanAdvisor(plan: plan)).touchUp(bodies: bodies)
        XCTAssertTrue(result.outcome.message.contains("Finished it as a stool"), result.outcome.message)
        XCTAssertNil(result.meshes[bodies[4].id], "the part left out of the plan is untouched")
        let legs = bodies[1...3].map { result.meshes[$0.id] ?? $0.mesh }
        for leg in legs { XCTAssertEqual(size(leg).x, size(legs[0]).x, accuracy: 1e-5) }
        XCTAssertEqual(result.styles[bodies[0].id]?.name, "pine")
        XCTAssertEqual(result.styles[bodies[1].id]?.name, "black")
        XCTAssertNil(result.styles[bodies[4].id])
    }

    func testAnInvalidModelPlanIsIgnored() {
        let sizes: [SIMD3<Float>] = [[0.008, 0.03, 0.008], [0.008, 0.03, 0.008]]
        let bad = DesignPlan(kind: "spaceship", groups: [group([7, 9])], reason: "")
        XCTAssertNil(DesignIntent.validated(bad, partSizes: sizes))
        let duplicated = DesignPlan(kind: " Table ", groups: [group([0, 1]), group([1], role: "b", material: "not-a-colour")], reason: "")
        let checked = DesignIntent.validated(duplicated, partSizes: sizes)
        XCTAssertEqual(checked?.groups.count, 1, "a part belongs to one group")
        XCTAssertEqual(checked?.kind, "table")
        let wildlyDifferent = DesignPlan(kind: "x", groups: [group([0, 1])], reason: "")
        XCTAssertNil(DesignIntent.validated(wildlyDifferent, partSizes: [[0.008, 0.03, 0.008], [0.06, 0.2, 0.06]]), "8 mm and 60 mm are not the same kind of part")
        let unknownColour = DesignPlan(kind: "x", groups: [group([0], material: "not-a-colour")], reason: "")
        XCTAssertEqual(DesignIntent.validated(unknownColour, partSizes: sizes)?.groups.first?.material, "")
    }

    func testTheModelCanNameAnyKindOfDesign() {
        let plan = DesignPlan(kind: "Robot", groups: [group([0])], reason: "")
        XCTAssertEqual(DesignIntent.validated(plan, partSizes: [[0.01, 0.01, 0.01]])?.kind, "robot")
        XCTAssertTrue(DesignIntent.isGeneric("assembly"))
        XCTAssertFalse(DesignIntent.isGeneric("robot"))
    }

    func testAPlateWithSloppyHolesGetsAnIdenticalMirroredPattern() async {
        func circle(_ c: SIMD2<Float>, _ r: Float) -> [SIMD2<Double>] {
            (0..<24).map { i in let a = Float(i) / 24 * 2 * .pi; return SIMD2<Double>(Double(c.x + cos(a) * r), Double(c.y + sin(a) * r)) }
        }
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0.1, 0), SIMD2(0.1, 0.06), SIMD2(0, 0.06)]
        let plate = try! GeometryBuilder.prism(outer: outer, holes: [
            circle([0.012, 0.011], 0.0035), circle([0.089, 0.0105], 0.004),
            circle([0.0115, 0.0495], 0.0045), circle([0.0885, 0.0488], 0.0038),
        ], height: 0.008, centered: false)
        let report = await TouchUpEngine(advisor: NoAdvisor()).touchUp(body: plate)
        let mesh = try! XCTUnwrap(report.mesh)
        let profile = MeshTouchUp.prismProfile(of: mesh)!
        XCTAssertEqual(profile.loops.count, 5)
        let holes = profile.loops.dropFirst().map { loop -> (c: SIMD2<Float>, r: Float) in
            let c = loop.reduce(SIMD2<Float>.zero, +) / Float(loop.count)
            return (c, simd_distance(loop[0], c))
        }
        for hole in holes { XCTAssertEqual(hole.r, holes[0].r, accuracy: 1e-5) }
        let centre = profile.loops[0].reduce(SIMD2<Float>.zero, +) / 4
        let offsets = holes.map { abs($0.c.x - centre.x) }
        for value in offsets { XCTAssertEqual(value, offsets[0], accuracy: 1e-5) }
    }
}

@MainActor
final class FinishApplicationTests: XCTestCase {
    func testFinishingAppliesToTheDocumentAndUndoes() async {
        let model = AppModel()
        let before = model.snapshotDocument()
        var bodies: [RenderMesh] = [block(0.12, 0.01, 0.07, at: [0.06, 0.005, -0.035])]
        for (x, z) in [(0.012, -0.012), (0.108, -0.012), (0.012, -0.058), (0.108, -0.058)] as [(Float, Float)] {
            bodies.append(block(0.008, 0.03, 0.008, at: [x, -0.015, z]))
        }
        let ids = model.addViewportSolids(bodies)
        let docBodies = zip(ids, bodies).map { (id: $0.0, mesh: $0.1) }
        let result = await TouchUpEngine(advisor: NoAdvisor()).touchUp(bodies: docBodies, styles: model.partStyles)
        let snapshot = model.snapshotDocument()
        model.applyTouchUp(result.meshes)
        model.applyFinish(styles: result.styles, additions: result.additions)
        XCTAssertGreaterThan(model.document.partStudio.orderedBodyIDs.count, ids.count + 1)
        XCTAssertFalse(model.partStyles.isEmpty)
        model.restoreDocument(snapshot)
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, ids.count + 1)
        XCTAssertTrue(model.partStyles.isEmpty)
        model.restoreDocument(before)
    }
}
