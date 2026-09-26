import XCTest
@testable import FoldForm

@MainActor
final class ImagineDictationTests: XCTestCase {
    func testInterimAppearsOnlyAsCaptionAndFinalIsAvailableForPrompt() async {
        let speech = ScriptedSpeechService()
        let dictation = ImagineDictation(speech: speech)
        await dictation.start()
        speech.emit(.interim("phone sta"))
        await waitUntil { dictation.interim == "phone sta" }
        XCTAssertNil(dictation.lastFinal)
        let final = FinalUtterance(text: "phone stand")
        speech.emit(.final(final))
        await waitUntil { dictation.lastFinal == final }
        XCTAssertEqual(dictation.interim, "")
        await dictation.stop()
        XCTAssertFalse(dictation.isListening)
    }

    func testCancelDropsLaterSpeech() async {
        let speech = ScriptedSpeechService()
        let dictation = ImagineDictation(speech: speech)
        await dictation.start()
        await dictation.cancel()
        speech.emit(.final(FinalUtterance(text: "add a hole")))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(dictation.lastFinal)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("event not received")
    }
}
