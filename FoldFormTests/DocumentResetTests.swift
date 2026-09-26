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

    func testRestoringASnapshotTakesBackAnExtrudeAndDelete() {
        let model = AppModel()
        let start = bodyCount(model)
        let beforeExtrude = model.snapshotDocument()
        let ids = model.addViewportSolids([GeometryBuilder.cylinder(radius: 0.01, height: 0.01)])
        XCTAssertEqual(bodyCount(model), start + 1)
        let beforeDelete = model.snapshotDocument()
        model.removeViewportSolid(bodyID: ids[0])
        XCTAssertEqual(bodyCount(model), start)
        model.restoreDocument(beforeDelete)
        XCTAssertEqual(bodyCount(model), start + 1, "delete undone")
        model.restoreDocument(beforeExtrude)
        XCTAssertEqual(bodyCount(model), start, "extrude undone")
    }

    func testRestoringASnapshotBringsBackAResetDocument() {
        let model = AppModel()
        model.addViewportSolids([GeometryBuilder.cylinder(radius: 0.01, height: 0.01)])
        let beforeReset = model.snapshotDocument()
        model.resetDocumentToInitialPlate()
        XCTAssertEqual(bodyCount(model), 1)
        model.restoreDocument(beforeReset)
        XCTAssertEqual(bodyCount(model), 2)
    }

    func testRestoringASnapshotBringsBackACut() {
        let model = AppModel()
        let before = model.snapshotDocument()
        let plate = model.document.partStudio.orderedBodyIDs.first.flatMap { model.document.partStudio.body($0)?.mesh }
        model.addViewportCuts([GeometryBuilder.cylinder(radius: 0.005, height: 0.2)])
        model.restoreDocument(before)
        let restored = model.document.partStudio.orderedBodyIDs.first.flatMap { model.document.partStudio.body($0)?.mesh }
        XCTAssertEqual(restored, plate)
    }
}
