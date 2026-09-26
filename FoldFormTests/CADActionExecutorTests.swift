import XCTest
import simd
@testable import FoldForm

@MainActor
final class CADActionExecutorTests: XCTestCase {
    private var model: AppModel!
    private var viewport: ViewportEntities!
    private var executor: CADActionExecutor!

    override func setUp() async throws {
        model = AppModel()
        viewport = ViewportEntities()
        viewport.update(appModel: model)
        executor = CADActionExecutor(appModel: model, viewport: viewport)
    }

    // MARK: Helpers

    private var ids: [UUID] { model.document.partStudio.orderedBodyIDs }
    private func mesh(_ id: UUID) -> RenderMesh { model.document.partStudio.body(id)!.mesh }
    private func bounds(_ id: UUID) -> (min: SIMD3<Float>, max: SIMD3<Float>) { mesh(id).boundingBox }
    private func size(_ id: UUID) -> SIMD3<Float> { let b = bounds(id); return b.max - b.min }
    private func volume(_ id: UUID) -> Float { mesh(id).solidProperties?.volume ?? 0 }
    private func meshes() -> [UUID: RenderMesh] { Dictionary(uniqueKeysWithValues: ids.map { ($0, mesh($0)) }) }

    @discardableResult
    private func make(_ action: CADAction, file: StaticString = #filePath, line: UInt = #line) -> UUID {
        let result = executor.run([action])
        XCTAssertNil(result.failure, "\(action) failed: \(result.failure ?? "")", file: file, line: line)
        return ids.last!
    }

    private func nearestAxis(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let i = (0..<3).max { abs(v[$0]) < abs(v[$1]) }!
        var axis = SIMD3<Float>.zero
        axis[i] = v[i] < 0 ? -1 : 1
        return axis
    }

    // MARK: Creating

    func testCubeIsThirtyMillimetresBesideTheDesignOnItsBaseAndSelected() {
        let plate = bounds(ids[0])
        let count = ids.count
        let cube = make(.createCube(size: 0.03))
        XCTAssertEqual(ids.count, count + 1)
        for axis in 0..<3 { XCTAssertEqual(size(cube)[axis], 0.03, accuracy: 1e-4) }
        XCTAssertGreaterThanOrEqual(bounds(cube).min.x, plate.max.x, "placed to the right of what is there")
        XCTAssertEqual(bounds(cube).min.y, plate.min.y, accuracy: 1e-5, "sits on the scene's base")
        XCTAssertEqual(viewport.selectedDocumentBodyID, cube)
    }

    func testBoxUsesWidthAcrossHeightUpAndDepthBack() {
        let box = make(.createBox(width: 0.02, depth: 0.04, height: 0.005))
        XCTAssertEqual(size(box).x, 0.02, accuracy: 1e-4)
        XCTAssertEqual(size(box).y, 0.005, accuracy: 1e-4)
        XCTAssertEqual(size(box).z, 0.04, accuracy: 1e-4)
    }

    func testCylinderStandsUpright() {
        let cylinder = make(.createCylinder(radius: 0.012, height: 0.03))
        XCTAssertEqual(size(cylinder).y, 0.03, accuracy: 1e-4)
        XCTAssertEqual(size(cylinder).x, 0.024, accuracy: 1e-3)
        XCTAssertEqual(size(cylinder).z, 0.024, accuracy: 1e-3)
        XCTAssertEqual(DesignScene.part(from: (cylinder, mesh(cylinder)))?.kind, .cylinder)
    }

    func testSecondCubeGoesBesideTheFirst() {
        let first = make(.createCube(size: 0.02))
        let second = make(.createCube(size: 0.02))
        XCTAssertGreaterThanOrEqual(bounds(second).min.x, bounds(first).max.x)
    }

    func testPrismIsCentredOnItsOutlineAndExtrudedAlongZ() {
        let triangle: [SIMD2<Float>] = [[0, 0], [0.04, 0], [0, 0.03]]
        let prism = make(.createPrism(outline: triangle, depth: 0.01))
        XCTAssertEqual(size(prism).x, 0.04, accuracy: 1e-4)
        XCTAssertEqual(size(prism).y, 0.03, accuracy: 1e-4)
        XCTAssertEqual(size(prism).z, 0.01, accuracy: 1e-4)
    }

    func testFromCentrePlacementIsRelativeToTheDesignAtTheStartOfTheRequest() {
        let plate = ids[0]
        let middle = mesh(plate).center
        let box = make(.createCube(size: 0.01, at: .fromCentre([0.05, 0.02, 0]), name: "a"))
        let c = mesh(box).center
        XCTAssertEqual(c.x, middle.x + 0.05, accuracy: 1e-4)
        XCTAssertEqual(c.y, middle.y + 0.02, accuracy: 1e-4)
    }

    func testAbsurdSizesAreRefusedAndChangeNothing() {
        let before = meshes()
        let result = executor.run([.createCube(size: 50)])
        XCTAssertEqual(result.failure, "That size is out of range")
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo)
    }

    // MARK: Moving

    func testMoveRightGoesAlongTheWorldAxisNearestTheCamerasRight() {
        let cube = make(.createCube(size: 0.03))
        let before = mesh(cube).center
        make(.move(target: .selected, by: .camera(.right, 0.02)))
        let expected = nearestAxis(viewport.viewAxes.right) * 0.02
        XCTAssertEqual(simd_length(mesh(cube).center - before - expected), 0, accuracy: 1e-5)
        XCTAssertEqual(viewport.selectedDocumentBodyID, cube, "the part stays selected")
    }

    func testMovingLeftIsTheOppositeAndANegativeDistanceAlsoReverses() {
        let cube = make(.createCube(size: 0.03))
        let start = mesh(cube).center
        make(.move(target: .selected, by: .camera(.left, 0.02)))
        let left = mesh(cube).center - start
        make(.move(target: .selected, by: .camera(.right, -0.02)))
        let again = mesh(cube).center - start
        XCTAssertEqual(simd_length(left + nearestAxis(viewport.viewAxes.right) * 0.02), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(again - 2 * left), 0, accuracy: 1e-5)
    }

    func testMoveUpRaisesTheBody() {
        let cube = make(.createCube(size: 0.03))
        let before = bounds(cube).min.y
        make(.move(target: .selected, by: .camera(.up, 0.01)))
        XCTAssertEqual(bounds(cube).min.y, before + 0.01, accuracy: 1e-5)
    }

    // MARK: Resizing

    func testAddingHeightGrowsAUprightFromItsBaseAndKeepsTheCentre() {
        let box = make(.createBox(width: 0.04, depth: 0.03, height: 0.02))
        let before = bounds(box)
        make(.resize(target: .selected, changes: [DimensionChange(axis: .y, mode: .add, value: 0.02)]))
        let after = bounds(box)
        XCTAssertEqual(after.min.y, before.min.y, accuracy: 1e-5)
        XCTAssertEqual(after.max.y, before.max.y + 0.02, accuracy: 1e-5)
        XCTAssertEqual((after.min.x + after.max.x) / 2, (before.min.x + before.max.x) / 2, accuracy: 1e-5)
        XCTAssertEqual((after.min.z + after.max.z) / 2, (before.min.z + before.max.z) / 2, accuracy: 1e-5)
    }

    func testThinnestSetsTheThinSideOfASlab() {
        let slab = make(.createBox(width: 0.04, depth: 0.06, height: 0.005))
        make(.resize(target: .selected, changes: [DimensionChange(axis: .thinnest, mode: .set, value: 0.015)]))
        XCTAssertEqual(size(slab).y, 0.015, accuracy: 1e-5)
        XCTAssertEqual(size(slab).x, 0.04, accuracy: 1e-5)
    }

    func testCylinderResizesItsDiameterOrHeight() {
        let cylinder = make(.createCylinder(radius: 0.01, height: 0.03))
        make(.resize(target: .selected, changes: [DimensionChange(axis: .y, mode: .set, value: 0.05)]))
        XCTAssertEqual(size(cylinder).y, 0.05, accuracy: 1e-4)
        make(.resize(target: .selected, changes: [DimensionChange(axis: .x, mode: .set, value: 0.03)]))
        XCTAssertEqual(size(cylinder).x, 0.03, accuracy: 1e-3)
        XCTAssertEqual(size(cylinder).z, 0.03, accuracy: 1e-3, "round stays round")
    }

    func testResizingARotatedPartIsRefused() {
        let box = make(.createBox(width: 0.04, depth: 0.03, height: 0.02))
        make(.rotate(target: .selected, axis: .z, angle: .pi / 4))
        let before = mesh(box)
        let result = executor.run([.resize(target: .selected, changes: [DimensionChange(axis: .y, mode: .add, value: 0.01)])])
        XCTAssertEqual(result.failure, "This part can't be resized after rotating")
        XCTAssertEqual(mesh(box), before)
    }

    func testResizeBelowNothingIsRefused() {
        make(.createBox(width: 0.04, depth: 0.03, height: 0.02))
        let result = executor.run([.resize(target: .selected, changes: [DimensionChange(axis: .y, mode: .add, value: -0.05)])])
        XCTAssertEqual(result.failure, "That size is out of range")
    }

    // MARK: Rotating, rounding, holes

    func testRotateKeepsVolumeAndCentreAndEnlargesTheBounds() {
        let cube = make(.createCube(size: 0.03))
        let volumeBefore = volume(cube), centreBefore = mesh(cube).center, sizeBefore = size(cube)
        make(.rotate(target: .selected, axis: .z, angle: .pi / 4))
        XCTAssertEqual(volume(cube), volumeBefore, accuracy: volumeBefore * 0.001)
        XCTAssertEqual(simd_length(mesh(cube).center - centreBefore), 0, accuracy: 1e-5)
        XCTAssertGreaterThan(size(cube).x, sizeBefore.x + 0.005)
        XCTAssertEqual(DesignScene.part(from: (cube, mesh(cube)))?.kind, .other)
    }

    func testRoundingChangesTheMeshButKeepsItsBounds() {
        let box = make(.createBox(width: 0.04, depth: 0.04, height: 0.01))
        let before = mesh(box), boundsBefore = bounds(box)
        make(.round(target: .selected, radius: 0.005))
        XCTAssertNotEqual(mesh(box), before)
        XCTAssertEqual(simd_length(bounds(box).min - boundsBefore.min), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(bounds(box).max - boundsBefore.max), 0, accuracy: 1e-4)
        XCTAssertLessThan(volume(box), before.solidProperties!.volume)
    }

    func testRoundingBiggerThanHalfTheShortestSideFails() {
        let box = make(.createBox(width: 0.04, depth: 0.04, height: 0.01))
        let before = mesh(box)
        let result = executor.run([.round(target: .selected, radius: 0.03)])
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(mesh(box), before)
    }

    func testHoleRemovesAboutPiRSquaredTimesThicknessFromOnlyTheSelectedBody() {
        let plate = ids[0]
        let plateBefore = mesh(plate)
        let slab = make(.createBox(width: 0.04, depth: 0.04, height: 0.01))
        let before = volume(slab)
        make(.addHole(target: .selected, diameter: 0.005))
        let removed = before - volume(slab)
        let expected = Float.pi * 0.0025 * 0.0025 * 0.01
        XCTAssertEqual(removed, expected, accuracy: expected * 0.05)
        XCTAssertEqual(mesh(plate), plateBefore, "other bodies are untouched")
    }

    func testHoleWiderThanThePartFails() {
        make(.createBox(width: 0.04, depth: 0.04, height: 0.01))
        XCTAssertNotNil(executor.run([.addHole(target: .selected, diameter: 0.05)]).failure)
    }

    // MARK: Duplicate and delete

    func testDuplicateAddsACopyBesideTheOriginalAndSelectsIt() {
        let cube = make(.createCube(size: 0.03))
        let count = ids.count
        make(.duplicate(target: .selected))
        XCTAssertEqual(ids.count, count + 1)
        let copy = ids.last!
        XCTAssertNotEqual(copy, cube)
        XCTAssertEqual(size(copy), size(cube))
        XCTAssertGreaterThan(simd_length(mesh(copy).center - mesh(cube).center), 0.03)
        XCTAssertEqual(viewport.selectedDocumentBodyID, copy)
    }

    func testDeleteRemovesANonPlateBody() {
        let cube = make(.createCube(size: 0.03))
        make(.delete(target: .selected))
        XCTAssertFalse(ids.contains(cube))
        XCTAssertNil(viewport.selectedDocumentBodyID)
    }

    func testThePlateCannotBeDeleted() {
        viewport.select(documentBodyID: ids[0])
        let count = ids.count
        let result = executor.run([.delete(target: .selected)])
        XCTAssertEqual(result.failure, "The base plate can't be deleted")
        XCTAssertEqual(ids.count, count)
    }

    // MARK: Failure behaviour

    func testAnEditWithNothingSelectedFailsAndLeavesTheDocumentAlone() {
        viewport.select(documentBodyID: nil)
        let before = meshes()
        for action: CADAction in [
            .move(target: .selected, by: .camera(.right, 0.01)),
            .rotate(target: .selected, axis: .y, angle: 0.5),
            .round(target: .selected, radius: 0.001),
            .addHole(target: .selected, diameter: 0.001),
            .duplicate(target: .selected), .delete(target: .selected),
            .resize(target: .selected, changes: [DimensionChange(axis: .y, mode: .add, value: 0.01)]),
        ] {
            XCTAssertEqual(executor.run([action]).failure, "Select a part first", "\(action)")
        }
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo)
    }

    func testAFailedEditKeepsTheCurrentSelection() {
        let cube = make(.createCube(size: 0.03))
        XCTAssertNotNil(executor.run([.round(target: .selected, radius: 0.5)]).failure)
        XCTAssertEqual(viewport.selectedDocumentBodyID, cube)
    }

    // MARK: One request, one undo

    func testThreeActionsMakeExactlyOneUndoStepAndUndoRemovesAllOfThem() {
        let before = meshes()
        let result = executor.run([
            .createCube(size: 0.03),
            .move(target: .selected, by: .camera(.right, 0.02)),
            .rotate(target: .selected, axis: .y, angle: 0.3),
        ])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.completed, 3)
        XCTAssertNotEqual(meshes(), before)
        viewport.undo()
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo, "one step, not three")
    }

    func testRunStopsAtTheFirstFailureAndKeepsEarlierWork() {
        let count = ids.count
        let result = executor.run([
            .createCube(size: 0.03),
            .round(target: .selected, radius: 0.5),
            .createCube(size: 0.02),
        ])
        XCTAssertEqual(result.completed, 1)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.results.count, 2, "the third never ran")
        XCTAssertEqual(ids.count, count + 1)
        viewport.undo()
        XCTAssertEqual(ids.count, count, "the partial work is still one undo step")
    }

    func testRunningNothingDoesNothing() {
        let before = meshes()
        XCTAssertEqual(executor.run([]), SequenceResult())
        XCTAssertEqual(meshes(), before)
    }

    func testUndoAndRedoActionsUseTheViewportHistory() {
        let count = ids.count
        make(.createCube(size: 0.03))
        XCTAssertNil(executor.run([.undo]).failure)
        XCTAssertEqual(ids.count, count)
        XCTAssertNil(executor.run([.redo]).failure)
        XCTAssertEqual(ids.count, count + 1)
        XCTAssertEqual(executor.run([.redo]).failure, "Nothing to redo")
    }

    func testCreatedBodiesJoinTheFoldSession() {
        make(.createCube(size: 0.03))
        XCTAssertEqual(viewport.captureDesign()?.bodies.count, ids.count)
    }
}
