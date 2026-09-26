import XCTest
@testable import FoldForm

/// One voice command or Imagine plan must be exactly one undo step, and a failed one must leave
/// nothing behind. These drive a `ViewportEntities` that was never attached to a RealityView.
@MainActor
final class ViewportTransactionTests: XCTestCase {
    private func makeModel() -> (AppModel, ViewportEntities) {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        return (model, viewport)
    }

    private func cube(at x: Float, size: Float = 0.02) -> RenderMesh {
        GeometryBuilder.box(width: Double(size), height: Double(size), depth: Double(size)).translated(by: SIMD3(x, 0, 0))
    }

    func testSuccessfulTransactionIsOneUndoStep() {
        let (model, viewport) = makeModel()
        let before = model.document.partStudio.orderedBodyIDs.count
        let ok = viewport.transact {
            model.addViewportSolids([cube(at: 0.1)])
            model.addViewportSolids([cube(at: 0.2)])
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, before + 2)
        viewport.undo()
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, before, "both steps should come back in one undo")
    }

    func testFailedTransactionRestoresTheDocumentAndAddsNoUndoStep() {
        let (model, viewport) = makeModel()
        let before = model.document.partStudio.orderedBodyIDs
        XCTAssertFalse(viewport.canUndo)
        let ok = viewport.transact {
            model.addViewportSolids([cube(at: 0.1)])
            return false
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs, before)
        XCTAssertFalse(viewport.canUndo, "a rolled-back transaction must not leave an undo entry")
    }

    func testUndoThenRedoRestores() {
        let (model, viewport) = makeModel()
        let before = model.document.partStudio.orderedBodyIDs.count
        viewport.transact { model.addViewportSolids([cube(at: 0.1)]); return true }
        viewport.undo()
        XCTAssertTrue(viewport.canRedo)
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, before)
        viewport.redo()
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, before + 1)
        XCTAssertFalse(viewport.canRedo)
        XCTAssertTrue(viewport.canUndo)
    }

    func testANewEditAfterUndoClearsRedo() {
        let (model, viewport) = makeModel()
        viewport.transact { model.addViewportSolids([cube(at: 0.1)]); return true }
        viewport.undo()
        XCTAssertTrue(viewport.canRedo)
        viewport.transact { model.addViewportSolids([cube(at: 0.3)]); return true }
        XCTAssertFalse(viewport.canRedo)
    }

    func testRedoWithNothingToRedoIsHarmless() {
        let (model, viewport) = makeModel()
        let before = model.document.partStudio.orderedBodyIDs
        viewport.redo()
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs, before)
    }

    func testSelectingADocumentBodyReportsItBack() {
        let (model, viewport) = makeModel()
        viewport.transact { model.addViewportSolids([cube(at: 0.1)]); return true }
        let ids = model.document.partStudio.orderedBodyIDs
        XCTAssertNil(viewport.selectedDocumentBodyID)
        viewport.select(documentBodyID: ids.last)
        XCTAssertEqual(viewport.selectedDocumentBodyID, ids.last)
        viewport.select(documentBodyID: nil)
        XCTAssertNil(viewport.selectedDocumentBodyID)
        XCTAssertEqual(viewport.bodyCount, ids.count)
    }

    func testApplyBodyEditReplacesTheMeshAsOneRegeneratedFeature() {
        let (model, viewport) = makeModel()
        viewport.transact { model.addViewportSolids([cube(at: 0.1)]); return true }
        let id = model.document.partStudio.orderedBodyIDs.last!
        let moved = cube(at: 0.1).translated(by: SIMD3(0.05, 0, 0))
        model.applyBodyEdit([id: moved], label: "Move")
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, moved)
        XCTAssertEqual(model.lastOperationMessage, "Move")
    }

    func testSnapshotsKeepColoursAcrossATransaction() {
        let (model, viewport) = makeModel()
        viewport.transact { model.addViewportSolids([cube(at: 0.1)]); return true }
        let id = model.document.partStudio.orderedBodyIDs.last!
        viewport.transact {
            model.setStyles([id: Palette.style("red")!])
            return false
        }
        XCTAssertNil(model.partStyles[id])
    }
}
