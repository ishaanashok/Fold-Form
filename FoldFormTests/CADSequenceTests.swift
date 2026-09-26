import XCTest
import simd
@testable import FoldForm

/// Sketch actions, compound requests, and what happens when one step of many fails.
@MainActor
final class CADSequenceTests: XCTestCase {
    private var model: AppModel!
    private var viewport: ViewportEntities!
    private var executor: CADActionExecutor!

    override func setUp() async throws {
        model = AppModel()
        viewport = ViewportEntities()
        viewport.update(appModel: model)
        executor = CADActionExecutor(appModel: model, viewport: viewport)
    }

    private var ids: [UUID] { model.document.partStudio.orderedBodyIDs }
    private func mesh(_ id: UUID) -> RenderMesh { model.document.partStudio.body(id)!.mesh }
    private func sortedSize(_ id: UUID) -> [Float] {
        let b = mesh(id).boundingBox
        let s = b.max - b.min
        return [s.x, s.y, s.z].sorted()
    }
    private var totalVolume: Float { ids.reduce(0) { $0 + (mesh($1).solidProperties?.volume ?? 0) } }
    private func meshes() -> [UUID: RenderMesh] { Dictionary(uniqueKeysWithValues: ids.map { ($0, mesh($0)) }) }

    // MARK: Sketching

    func testStartSketchBeginsAndASecondStartIsRefused() {
        XCTAssertNil(executor.run([.startSketch]).failure)
        XCTAssertTrue(viewport.sketch.isActive)
        XCTAssertEqual(executor.run([.startSketch]).failure, "Already sketching")
    }

    func testSketchActionsNeedASketch() {
        for action: CADAction in [.addRectangle(width: 0.04, height: 0.06), .addCircle(radius: 0.01), .addLine(dx: 0.01, dy: 0), .extrude(distance: 0.01, cut: false), .finishSketch] {
            XCTAssertEqual(executor.run([action]).failure, "Start a sketch first", "\(action)")
        }
    }

    func testRectangleIsCentredOnTheSketchOrigin() {
        executor.run([.startSketch])
        XCTAssertNil(executor.run([.addRectangle(width: 0.04, height: 0.06)]).failure)
        XCTAssertEqual(viewport.sketch.shapes, [.rectangle([-0.02, -0.03], [0.02, 0.03])])
    }

    func testCircleAndLinesJoinTheSketch() {
        executor.run([.startSketch])
        XCTAssertNil(executor.run([.addCircle(radius: 0.012)]).failure)
        XCTAssertNil(executor.run([.addLine(dx: 0.02, dy: 0), .addLine(dx: 0, dy: 0.02)]).failure)
        XCTAssertEqual(viewport.sketch.shapes, [
            .circle(center: .zero, radius: 0.012),
            .line([0, 0], [0.02, 0]),
            .line([0.02, 0], [0.02, 0.02]),
        ], "each line continues from the end of the last")
    }

    func testTinyShapesAreRefused() {
        executor.run([.startSketch])
        XCTAssertNotNil(executor.run([.addRectangle(width: 0.0005, height: 0.05)]).failure)
        XCTAssertTrue(viewport.sketch.shapes.isEmpty)
    }

    func testFinishSketchDiscardsTheShapes() {
        executor.run([.startSketch, .addRectangle(width: 0.04, height: 0.06)])
        XCTAssertNil(executor.run([.finishSketch]).failure)
        XCTAssertFalse(viewport.sketch.isActive)
        XCTAssertTrue(viewport.sketch.shapes.isEmpty)
    }

    func testExtrudeAddsABodyOfTheRightSizeAndEndsTheSketch() {
        let count = ids.count
        executor.run([.startSketch, .addRectangle(width: 0.04, height: 0.06)])
        let result = executor.run([.extrude(distance: 0.02, cut: false)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(ids.count, count + 1)
        let size = sortedSize(ids.last!)
        XCTAssertEqual(size[0], 0.02, accuracy: 1e-4)
        XCTAssertEqual(size[1], 0.04, accuracy: 1e-4)
        XCTAssertEqual(size[2], 0.06, accuracy: 1e-4)
        XCTAssertFalse(viewport.sketch.isActive)
        XCTAssertEqual(viewport.selectedDocumentBodyID, ids.last, "the new part is selected")
    }

    func testExtrudeCutRemovesMaterial() {
        let before = totalVolume
        executor.run([.startSketch, .addRectangle(width: 0.01, height: 0.01)])
        XCTAssertNil(executor.run([.extrude(distance: 0.003, cut: true)]).failure)
        XCTAssertLessThan(totalVolume, before - 1e-9)
        XCTAssertEqual(ids.count, 1, "a cut adds no body")
    }

    func testExtrudeWithNothingDrawnAsksForAShape() {
        executor.run([.startSketch])
        XCTAssertEqual(executor.run([.extrude(distance: 0.01, cut: false)]).failure, "Draw a shape first")
        XCTAssertTrue(viewport.sketch.isActive, "the sketch is still open")
    }

    func testExtrudeDistanceOutsideTheSliderRangeIsRefused() {
        executor.run([.startSketch, .addRectangle(width: 0.04, height: 0.06)])
        XCTAssertEqual(executor.run([.extrude(distance: 0.5, cut: false)]).failure, "That distance is out of range")
        XCTAssertEqual(executor.run([.extrude(distance: 0.0005, cut: false)]).failure, "That distance is out of range")
    }

    // MARK: Undo

    func testRectangleThenExtrudeInOneRequestIsOneUndoStep() {
        let before = meshes()
        let result = executor.run([.startSketch, .addRectangle(width: 0.04, height: 0.06), .extrude(distance: 0.02, cut: false)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.completed, 3)
        XCTAssertNotEqual(meshes(), before)
        viewport.undo()
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo, "exactly one step")
    }

    func testSketchOnlyStepsDoNotAddUndoEntries() {
        executor.run([.startSketch])
        executor.run([.addRectangle(width: 0.04, height: 0.06)])
        XCTAssertFalse(viewport.canUndo, "the sketch has its own undo")
        viewport.undo()
        XCTAssertTrue(viewport.sketch.shapes.isEmpty, "undo takes back the shape first")
    }

    func testAnExtrudedPartCanBeMovedInTheSameRequest() {
        let result = executor.run([
            .startSketch, .addRectangle(width: 0.04, height: 0.06), .extrude(distance: 0.02, cut: false),
            .move(target: .selected, by: .camera(.up, 0.01)),
        ])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.completed, 4)
    }

    // MARK: Atomic

    func testAnAtomicPlanWithAFailingFourthOfFiveLeavesEverythingAsItWas() {
        let before = viewport.captureDesign()?.bodies.map(\.mesh)
        let beforeMeshes = meshes()
        let result = executor.runAtomically([
            .createCube(size: 0.03),
            .move(target: .selected, by: .camera(.right, 0.02)),
            .rotate(target: .selected, axis: .y, angle: 0.4),
            .round(target: .selected, radius: 0.5),
            .createCube(size: 0.02),
        ])
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.completed, 0, "nothing was kept")
        XCTAssertEqual(meshes(), beforeMeshes)
        XCTAssertEqual(viewport.captureDesign()?.bodies.map(\.mesh), before)
        XCTAssertFalse(viewport.canUndo, "no undo entry for a plan that did not happen")
    }

    func testARolledBackPlanAlsoClosesASketchItOpened() {
        let result = executor.runAtomically([.startSketch, .addRectangle(width: 0.04, height: 0.06), .round(target: .existing(9), radius: 0.001)])
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(viewport.sketch.isActive)
    }

    func testASuccessfulAtomicPlanIsOneUndoStep() {
        let before = meshes()
        let result = executor.runAtomically([.createCube(size: 0.03), .createCube(size: 0.02)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.completed, 2)
        viewport.undo()
        XCTAssertEqual(meshes(), before)
    }

    // MARK: Body references (Imagine)

    func testExistingAndNamedTargetsRefer​ToTheRightBodies() {
        let plate = ids[0]
        let result = executor.runAtomically([
            .createCube(size: 0.02, at: .beside, name: "knob"),
            .move(target: .named("knob"), by: .world([0, 0.01, 0])),
            .move(target: .existing(0), by: .world([0, 0.005, 0])),
        ])
        XCTAssertNil(result.failure)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(executor.runAtomically([.move(target: .existing(7), by: .world([0, 0, 0.01]))]).failure, "There is no part P7")
        XCTAssertEqual(executor.runAtomically([.move(target: .named("nope"), by: .world([0, 0, 0.01]))]).failure, "There is no part called nope")
        XCTAssertEqual(ids[0], plate)
    }
}
