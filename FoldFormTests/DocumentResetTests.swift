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
