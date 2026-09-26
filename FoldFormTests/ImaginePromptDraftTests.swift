import XCTest
@testable import FoldForm

final class ImaginePromptDraftTests: XCTestCase {
    func testFinalSentenceIsAppendedOnceEvenIfObservedAgainAfterStop() {
        var draft = ImaginePromptDraft(text: "Make a bracket")
        let sentence = FinalUtterance(text: "with a sloped support")
        draft.append(sentence)
        draft.append(sentence)
        XCTAssertEqual(draft.text, "Make a bracket with a sloped support")
    }

    func testRepeatedWordsFromDifferentFinalSentencesAreKept() {
        var draft = ImaginePromptDraft()
        draft.append(FinalUtterance(text: "add a tab"))
        draft.append(FinalUtterance(text: "add a tab"))
        XCTAssertEqual(draft.text, "add a tab add a tab")
    }
}
