import XCTest
import simd
@testable import FoldForm

final class FoldSessionTests: XCTestCase {
    private let block = GeometryBuilder.box(width: 0.12, height: 0.016, depth: 0.05)
    private func frame(x: Float = 0) -> FoldFrame {
        FoldFrame(pivot: SIMD3<Float>(x, -0.008, 0), axis: SIMD3<Float>(0, 0, -1), normal: SIMD3<Float>(1, 0, 0))
    }
    private let bend40 = 40 * Double.pi / 180
    private let flat = 0.0

    func testNothingToHoldWhenFlat() {
        var s = FoldSession(source: block)
        XCTAssertFalse(s.canHold(bend: flat))
        XCTAssertFalse(s.hold(bend: flat, frame: frame()))
        XCTAssertFalse(s.hold(bend: 0.5 * .pi / 180, frame: frame()), "within 1° of flat counts as flat")
        XCTAssertEqual(s.foldCount, 0)
        XCTAssertFalse(s.isHolding)
    }

    func testLiveFoldFollowsTheHingeUntilHeld() {
        let s = FoldSession(source: block)
        XCTAssertEqual(s.displayedMesh(bend: flat, frame: frame()), block)
        XCTAssertNotEqual(s.displayedMesh(bend: bend40, frame: frame()), block)
    }

    /// The reported request: press hold and the shape stays where it was folded to.
    func testHoldFreezesTheShapeAtTheCurrentFold() {
        var s = FoldSession(source: block)
        let shown = s.displayedMesh(bend: bend40, frame: frame())
        XCTAssertTrue(s.hold(bend: bend40, frame: frame()))
        XCTAssertTrue(s.isHolding)
        XCTAssertEqual(s.foldCount, 1)
        XCTAssertEqual(s.displayedMesh(bend: bend40, frame: frame()), shown, "holding doesn't change what's on screen")
        // Moving the hinge or the view no longer changes anything.
        XCTAssertEqual(s.displayedMesh(bend: 1.5, frame: frame(x: 0.03)), shown)
        XCTAssertEqual(s.displayedMesh(bend: 0.2, frame: frame(x: -0.03)), shown)
        XCTAssertFalse(s.canHold(bend: bend40), "already holding")
    }

    /// The hold lasts until the hinge is back to flat, not just until it opens a bit.
    func testHoldOnlyReleasesWhenTheHingeIsBackAtFlat() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame())
        XCTAssertFalse(s.bendChanged(bend40))
        XCTAssertFalse(s.bendChanged(20 * .pi / 180))
        XCTAssertFalse(s.bendChanged(5 * .pi / 180))
        XCTAssertTrue(s.isHolding, "5° open is still held")
        XCTAssertTrue(s.bendChanged(0.5 * .pi / 180), "flat releases it")
        XCTAssertFalse(s.isHolding)
        XCTAssertFalse(s.bendChanged(0), "already released")
    }

    func testAfterReleaseTheShapeStaysFoldedAtFlat() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame())
        let held = s.displayedMesh(bend: bend40, frame: frame())
        s.bendChanged(0)
        XCTAssertEqual(s.displayedMesh(bend: 0, frame: frame()), held, "opening the phone flat does not unfold the held fold")
        XCTAssertNotEqual(s.displayedMesh(bend: 0, frame: frame()), block)
    }

    /// The reported request: folds stack, each one working off what was folded before.
    func testNextFoldBuildsOnTheHeldShape() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame(x: 0))
        s.bendChanged(0)
        let firstFold = s.displayedMesh(bend: 0, frame: frame())

        // Fold again somewhere else.
        let stacked = s.displayedMesh(bend: bend40, frame: frame(x: 0.03))
        XCTAssertNotEqual(stacked, firstFold)
        XCTAssertNotEqual(stacked, BendDeformer.deform(block, bendAngleRadians: bend40, frame: frame(x: 0.03)),
                          "it must include the earlier fold, not start from the flat block again")
        XCTAssertEqual(stacked, BendDeformer.deform(firstFold, bendAngleRadians: bend40, frame: frame(x: 0.03)))

        XCTAssertTrue(s.hold(bend: bend40, frame: frame(x: 0.03)))
        XCTAssertEqual(s.foldCount, 2)
        XCTAssertEqual(s.displayedMesh(bend: 0, frame: frame()), stacked)
    }

    func testUndoRemovesTheLastHeldFoldOnly() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame(x: 0)); s.bendChanged(0)
        let first = s.base
        s.hold(bend: bend40, frame: frame(x: 0.03)); s.bendChanged(0)
        XCTAssertEqual(s.foldCount, 2)

        s.undo()
        XCTAssertEqual(s.foldCount, 1)
        XCTAssertEqual(s.base, first)
        s.undo()
        XCTAssertEqual(s.foldCount, 0)
        XCTAssertEqual(s.base, block)
        s.undo()   // nothing left: harmless
        XCTAssertEqual(s.foldCount, 0)
    }

    func testUndoWhileHeldGoesBackToFollowingTheHinge() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame())
        s.undo()
        XCTAssertFalse(s.isHolding)
        XCTAssertNotEqual(s.displayedMesh(bend: bend40, frame: frame()), block)
    }

    func testResetForANewBlockClearsEverything() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame())
        let other = GeometryBuilder.box(width: 0.05, height: 0.05, depth: 0.05)
        s.reset(source: other)
        XCTAssertEqual(s.foldCount, 0)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.base, other)
    }

    func testRevisionChangesOnlyWhenTheHeldStateDoes() {
        var s = FoldSession(source: block)
        let r0 = s.revision
        s.bendChanged(bend40)                                   // nothing held: no change
        XCTAssertEqual(s.revision, r0)
        s.hold(bend: bend40, frame: frame())
        let r1 = s.revision
        XCTAssertGreaterThan(r1, r0)
        s.bendChanged(bend40)                                   // still held: no change
        XCTAssertEqual(s.revision, r1)
        s.bendChanged(0)
        XCTAssertGreaterThan(s.revision, r1)
    }

    func testClearFoldsReturnsToTheOriginalBlock() {
        var s = FoldSession(source: block)
        s.hold(bend: bend40, frame: frame(x: 0)); s.bendChanged(0)
        s.hold(bend: bend40, frame: frame(x: 0.03))
        s.clearFolds()
        XCTAssertEqual(s.foldCount, 0)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.base, block)
        XCTAssertEqual(s.displayedMesh(bend: 0, frame: frame()), block)
    }
}
