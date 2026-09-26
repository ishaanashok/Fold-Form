import XCTest
@testable import FoldForm

@MainActor
final class DocumentResetTests: XCTestCase {
    func testResetDropsViewportSolidsAndKeepsOnePlate() {
        let model = AppModel()
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, 1)
        model.addViewportSolids([GeometryBuilder.cylinder(radius: 0.01, height: 0.01), GeometryBuilder.cylinder(radius: 0.02, height: 0.01)])
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, 3)
        model.resetDocumentToInitialPlate()
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, 1)
    }

    func testNoHoleInTheInitialPlate() {
        let model = AppModel()
        let features = model.document.partStudio.featureTree.features
        XCTAssertFalse(features.contains { $0 is HoleFeature })
    }
}

@MainActor
final class UndoEditTests: XCTestCase {
    private func bodyCount(_ m: AppModel) -> Int { m.document.partStudio.orderedBodyIDs.count }

    func testUndoTakesBackTheLastExtrudeAndDelete() {
        let model = AppModel()
        let start = bodyCount(model)
        XCTAssertFalse(model.canUndoEdit)
        let ids = model.addViewportSolids([GeometryBuilder.cylinder(radius: 0.01, height: 0.01)])
        XCTAssertEqual(bodyCount(model), start + 1)
        XCTAssertTrue(model.canUndoEdit)
        model.removeViewportSolid(bodyID: ids[0])
        XCTAssertEqual(bodyCount(model), start)
        model.undoLastEdit()
        XCTAssertEqual(bodyCount(model), start + 1, "delete undone")
        model.undoLastEdit()
        XCTAssertEqual(bodyCount(model), start, "extrude undone")
        XCTAssertFalse(model.canUndoEdit)
        XCTAssertFalse(model.undoLastEdit())
    }

    func testResetClearsTheUndoHistory() {
        let model = AppModel()
        model.addViewportSolids([GeometryBuilder.cylinder(radius: 0.01, height: 0.01)])
        model.resetDocumentToInitialPlate()
        XCTAssertFalse(model.canUndoEdit)
    }
}
