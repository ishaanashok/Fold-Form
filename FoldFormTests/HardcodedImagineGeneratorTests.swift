import XCTest
import simd
@testable import FoldForm

@MainActor
final class HardcodedImagineGeneratorTests: XCTestCase {
    private var model: AppModel!
    private var viewport: ViewportEntities!
    private var executor: CADActionExecutor!
    private var ids: [UUID] { model.document.partStudio.orderedBodyIDs }

    override func setUp() async throws {
        model = AppModel()
        viewport = ViewportEntities()
        viewport.update(appModel: model)
        executor = CADActionExecutor(appModel: model, viewport: viewport)
    }

    private func bounds(_ bodies: some Sequence<UUID>) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let boxes = bodies.map { model.document.partStudio.body($0)!.mesh.boundingBox }
        return (boxes.map(\.min).reduce(boxes[0].min, simd_min), boxes.map(\.max).reduce(boxes[0].max, simd_max))
    }

    private func run(_ imagine: ImagineSession, _ prompt: String) async -> [UUID] {
        let before = Set(ids)
        await imagine.generate(prompt: prompt, sketchPNG: Data([1]), polylines: [])
        guard case .done = imagine.phase else { XCTFail("\(prompt) should succeed, got \(imagine.phase)"); return [] }
        return ids.filter { !before.contains($0) }
    }

    func testBothPlansPassTheValidator() throws {
        for plan in [HardcodedImagineGenerator.table(beside: [12, 1.6, 5]), HardcodedImagineGenerator.chair(beside: [30, 8, 10])] {
            XCTAssertLessThanOrEqual(plan.steps.count, 12)
            XCTAssertEqual(try ImaginePlanValidator.validate(plan, bodyCount: 1, revision: 0, currentRevision: 0, allowDelete: false).count, plan.steps.count)
        }
    }

    func testReadsTheDesignSizeFromTheDescription() {
        let extent = HardcodedImagineGenerator.extent(from: "The design is 120.0 mm wide (x), 16.0 mm tall (y, up) and 50.0 mm deep (z).\nParts:")
        XCTAssertEqual(extent, [12, 1.6, 5])
    }

    func testTableThenChairStandBesideTheDesignOnTheSameFloor() async {
        let imagine = ImagineSession(appModel: model, viewport: viewport, executor: executor, generator: HardcodedImagineGenerator(latency: .zero))
        let plate = bounds(ids)

        let table = await run(imagine, "create a table")
        XCTAssertEqual(table.count, 5)
        let tableBox = bounds(table)
        XCTAssertGreaterThan(tableBox.min.x, plate.max.x)
        XCTAssertEqual(tableBox.min.y, plate.min.y, accuracy: 1e-4)
        XCTAssertEqual(tableBox.max.y - tableBox.min.y, 0.08, accuracy: 1e-4)

        let chair = await run(imagine, "add a lamp on the table")
        XCTAssertEqual(chair.count, 6, "the follow-up request builds the chair")
        let chairBox = bounds(chair)
        XCTAssertGreaterThan(chairBox.min.x, tableBox.max.x)
        XCTAssertEqual(chairBox.min.y, plate.min.y, accuracy: 1e-4)
    }

    func testChairKeywordWinsAndUndoneTableIsBuiltAgain() async {
        let generator = HardcodedImagineGenerator(latency: .zero)
        let imagine = ImagineSession(appModel: model, viewport: viewport, executor: executor, generator: generator)
        let chair = await run(imagine, "make me a chair")
        XCTAssertEqual(chair.count, 6)

        let table = await run(imagine, "create a table")
        XCTAssertEqual(table.count, 5)
        viewport.undo()
        let again = await run(imagine, "create a table")
        XCTAssertEqual(again.count, 5, "an undone table is rebuilt rather than skipped")
    }
}
