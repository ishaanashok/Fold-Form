import XCTest
@testable import FoldForm

private final class FakeNeedle: NeedleRuntime, @unchecked Sendable {
    var loaded = true
    var reply: Result<String, Error> = .success(#"{"function_calls":[],"confidence":0.9}"#)
    private(set) var prompts: [String] = []
    private(set) var toolNames: [[String]] = []
    var isLoaded: Bool { loaded }
    func generate(prompt: String, toolsJSON: String) async throws -> String {
        prompts.append(prompt)
        let tools = (try? JSONSerialization.jsonObject(with: Data(toolsJSON.utf8))) as? [[String: Any]] ?? []
        toolNames.append(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        return try reply.get()
    }
}

private struct Boom: Error {}

private func reply(_ calls: String, confidence: Double = 0.9) -> String {
    #"{"type":"call","success":true,"function_calls":\#(calls),"suppressed_calls":[],"reasoning":"x","confidence":\#(confidence)}"#
}

final class CompositeInterpreterTests: XCTestCase {
    private let none = ToolContext(isSketching: false, selection: .none, canUndo: false, canRedo: false)
    private let box = ToolContext(isSketching: false, selection: .box, canUndo: true, canRedo: false)
    private func utterance(_ text: String) -> FinalUtterance { FinalUtterance(text: text) }

    // MARK: NeedleInterpreter

    func testValidCallsAreParsed() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"create_cube","arguments":{"size":3,"unit":"cm"}}]"#))
        let proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("make a cube that's three centimeters wide"), context: none)
        XCTAssertEqual(proposal, .calls([ToolCall(name: "create_cube", arguments: ["size": .number(3), "unit": .string("cm")])]))
    }

    func testTheUtteranceIsThePromptAndOnlyTheToolsForThisContextAreOffered() async {
        let runtime = FakeNeedle()
        _ = await NeedleInterpreter(runtime: runtime).propose(utterance("make a cube"), context: none)
        XCTAssertEqual(runtime.prompts, ["make a cube"])
        let offered = Set(runtime.toolNames[0])
        XCTAssertTrue(offered.contains("create_cube"))
        XCTAssertFalse(offered.contains("add_rectangle"), "sketch tools are hidden outside a sketch")
        XCTAssertFalse(offered.contains("move_selected"), "nothing selected, nothing to move")
    }

    func testAnEmptyListIsNothingToDo() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply("[]"))
        let proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("what's the weather"), context: none)
        XCTAssertEqual(proposal, .empty)
    }

    func testAWithheldCallIsTreatedAsEmpty() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(#"{"function_calls":[],"suppressed_calls":[{"name":"create_cube","arguments":{"size":3,"unit":"cm"}}],"confidence":0.05}"#)
        let proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("don't make a cube"), context: none)
        XCTAssertEqual(proposal, .empty)
    }

    func testMalformedJSONIsUnusable() async {
        let runtime = FakeNeedle()
        for text in ["not json", "{", #"{"function_calls":"nope"}"#, #"{"function_calls":[{"arguments":{}}]}"#, ""] {
            runtime.reply = .success(text)
            let proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("x"), context: none)
            XCTAssertEqual(proposal, .unusable, text)
        }
    }

    func testARuntimeErrorOrAnUnloadedModelIsUnusable() async {
        let runtime = FakeNeedle()
        runtime.reply = .failure(Boom())
        var proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("x"), context: none)
        XCTAssertEqual(proposal, .unusable)
        runtime.loaded = false
        proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("x"), context: none)
        XCTAssertEqual(proposal, .unusable)
        XCTAssertEqual(runtime.prompts.count, 1, "an unloaded model is not called")
    }

    func testBooleansAndIntegersAreKept() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"extrude","arguments":{"distance":20,"unit":"mm","flag":true}}]"#))
        let proposal = await NeedleInterpreter(runtime: runtime).propose(utterance("cut twenty millimeters"), context: ToolContext(isSketching: true, selection: .none, canUndo: false, canRedo: false))
        XCTAssertEqual(proposal, .calls([ToolCall(name: "extrude", arguments: ["distance": .number(20), "unit": .string("mm"), "flag": .bool(true)])]))
    }

    // MARK: Composite

    /// A sentence the rules do not recognise, so only the model can read it.
    private let unruly = "kindly produce a cubic solid seven centimeters across"

    private func composite(_ runtime: FakeNeedle) -> CompositeInterpreter {
        CompositeInterpreter(needle: NeedleInterpreter(runtime: runtime), fallback: RuleBasedInterpreter())
    }

    private func cube(_ size: Int, unit: String = "cm") -> String {
        reply(#"[{"name":"create_cube","arguments":{"size":\#(size),"unit":"\#(unit)"}}]"#)
    }

    func testTheRulesComeFirstAndNeedleIsNotAskedWhenTheyUnderstand() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(cube(9))
        let result = await composite(runtime).interpret(utterance("make a 3 centimeter cube"), context: none)
        guard case .calls(let calls) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(calls.first?.arguments["size"], .number(3))
        XCTAssertTrue(runtime.prompts.isEmpty)
    }

    func testARuleQuestionIsNotOverriddenByTheModel() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"delete_selected","arguments":{}}]"#))
        let result = await composite(runtime).interpret(utterance("move it up"), context: box)
        XCTAssertEqual(result, .clarify("How far?"))
        XCTAssertTrue(runtime.prompts.isEmpty)
    }

    func testNeedleReadsWhatTheRulesCannot() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(cube(7))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .calls([ToolCall(name: "create_cube", arguments: ["size": .number(7), "unit": .string("cm")])]))
    }

    func testAToolThatIsNotAvailableHereIsRejected() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"add_rectangle","arguments":{"width":7,"height":7,"unit":"cm"}}]"#))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testACallThatFailsValidationIsRejectedNotRun() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(cube(-7))
        let result = await composite(runtime).interpret(utterance("kindly produce a cubic solid minus seven centimeters across"), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testAnUnknownToolNameIsRejected() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"format_disk","arguments":{}}]"#))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testALowConfidenceAnswerIsRejected() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"create_cube","arguments":{"size":7,"unit":"cm"}}]"#, confidence: 0.2))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testANumberTheUserNeverSaidIsRejected() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(cube(9))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand), "seven was said, nine was not")
    }

    func testAToolThatDoesNotMatchAnythingSaidIsRejected() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply(#"[{"name":"delete_selected","arguments":{}}]"#))
        let result = await composite(runtime).interpret(utterance("kindly produce a cubic solid"), context: box)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand), "a delete nobody asked for must not run")
    }

    func testAnEmptyNeedleAnswerLeavesTheRulesAnswer() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(reply("[]"))
        let result = await composite(runtime).interpret(utterance(unruly), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testWithoutNeedleTheRulesStillWork() async {
        let runtime = FakeNeedle()
        runtime.loaded = false
        let result = await composite(runtime).interpret(utterance("make a 3 centimeter cube"), context: none)
        guard case .calls = result else { return XCTFail("\(result)") }
        XCTAssertTrue(runtime.prompts.isEmpty)
    }

    func testImagineWordsNeverGoToNeedle() async {
        let runtime = FakeNeedle()
        runtime.reply = .success(cube(3))
        let result = await composite(runtime).interpret(utterance("imagine a bracket with ventilation slots"), context: none)
        XCTAssertEqual(result, .needsImagine)
        XCTAssertTrue(runtime.prompts.isEmpty)
    }
}
