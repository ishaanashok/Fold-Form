import XCTest
@testable import FoldForm

final class AppleSpeechResultRouterTests: XCTestCase {
    func testOnlyAFinalResultCanBecomeAnExecutableUtterance() {
        var router = AppleSpeechResultRouter()
        XCTAssertEqual(router.accept("Make a table", isFinal: false, segment: 1), .interim("Make a table"))
        XCTAssertEqual(router.accept("Make a table.", isFinal: false, segment: 1), .interim("Make a table."))

        guard case .final(let utterance) = router.accept("Make a table.", isFinal: true, segment: 1) else {
            return XCTFail("a finalized phrase must be sent to the command session")
        }
        XCTAssertEqual(utterance.text, "Make a table.")
        XCTAssertNil(router.accept("Make a table.", isFinal: true, segment: 1), "a repeated final must not execute twice")
        XCTAssertNil(router.accept("Make a table.", isFinal: false, segment: 1), "late interim text cannot undo finalization")
    }

    func testASecondPhraseCanRepeatTheSameWords() {
        var router = AppleSpeechResultRouter()
        XCTAssertNotNil(router.accept("Undo", isFinal: true, segment: 1))
        XCTAssertNotNil(router.accept("Undo", isFinal: true, segment: 2))
        XCTAssertNil(router.accept("  ", isFinal: true, segment: 3))
    }

    func testARecognitionSegmentCanBeFinishedOnlyOnce() {
        var router = AppleSpeechResultRouter()
        XCTAssertTrue(router.beginFinishing(segment: 1))
        XCTAssertFalse(router.beginFinishing(segment: 1), "pause and Stop must not end the same request twice")
        XCTAssertTrue(router.beginFinishing(segment: 2))
    }
}
