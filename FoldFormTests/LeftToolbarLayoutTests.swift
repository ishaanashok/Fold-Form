import XCTest
@testable import FoldForm

final class LeftToolbarLayoutTests: XCTestCase {
    func testFlatShowsPrimaryToolsAndHidesLock() {
        let layout = LeftToolbarLayout(isFolding: false, isHolding: false, isBendingSelection: false, hasFolds: false)
        XCTAssertEqual(layout.visible, [.sketch, .revert, .move, .disclosure])
        XCTAssertFalse(layout.visible.contains(.hold))
    }

    func testFoldingHoldingOrSelectionBendShowsOnlyLock() {
        for layout in [
            LeftToolbarLayout(isFolding: true, isHolding: false, isBendingSelection: false, hasFolds: false),
            LeftToolbarLayout(isFolding: false, isHolding: true, isBendingSelection: false, hasFolds: true),
            LeftToolbarLayout(isFolding: false, isHolding: false, isBendingSelection: true, hasFolds: false),
        ] {
            XCTAssertEqual(layout.visible, [.hold])
        }
    }

    func testDropdownContainsExactlyNonPrimaryToolsAndConditionalFoldActions() {
        let flat = LeftToolbarLayout(isFolding: false, isHolding: false, isBendingSelection: false, hasFolds: false)
        XCTAssertEqual(flat.dropdown, [.mic, .touchUp, .share, .viewOptions, .resetEverything])
        let withFolds = LeftToolbarLayout(isFolding: false, isHolding: false, isBendingSelection: false, hasFolds: true)
        XCTAssertEqual(withFolds.dropdown, [.mic, .touchUp, .share, .viewOptions, .resetEverything, .undoFold, .resetFolds])
        XCTAssertTrue(Set(withFolds.visible).isDisjoint(with: withFolds.dropdown))
    }
}
