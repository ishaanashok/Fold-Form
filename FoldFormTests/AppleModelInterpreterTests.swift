import XCTest
@testable import FoldForm

private final class FakeAppleModel: AppleCommandModel, @unchecked Sendable {
    var available = true
    var proposed: [ToolCall] = []
    var receivedPrompts: [String] = []
    var isAvailable: Bool { available }

    func propose(_ text: String, toolsJSON: String) async throws -> [ToolCall] {
        receivedPrompts.append(text)
        return proposed
    }
}

final class AppleModelInterpreterTests: XCTestCase {
    private let none = ToolContext(isSketching: false, selection: .none, canUndo: false, canRedo: false)

    func testRulesHandleKnownCommandsWithoutAskingTheModel() async {
        let model = FakeAppleModel()
        model.proposed = [ToolCall(name: "create_cube", arguments: ["size": .number(9), "unit": .string("cm")])]
        let interpreter = CompositeInterpreter(model: AppleModelInterpreter(model: model), fallback: RuleBasedInterpreter())
        let result = await interpreter.interpret(FinalUtterance(text: "make a 3 centimeter cube"), context: none)
        guard case .calls(let calls) = result else { return XCTFail("expected a cube") }
        XCTAssertEqual(calls.first?.arguments["size"], .number(3))
        XCTAssertTrue(model.receivedPrompts.isEmpty)
    }

    func testAppleModelCanInterpretAnUnrecognizedButSupportedCommand() async {
        let model = FakeAppleModel()
        model.proposed = [ToolCall(name: "create_cube", arguments: ["size": .number(7), "unit": .string("cm")])]
        let interpreter = CompositeInterpreter(model: AppleModelInterpreter(model: model), fallback: RuleBasedInterpreter())
        let result = await interpreter.interpret(FinalUtterance(text: "produce a cubic solid seven centimeters across"), context: none)
        XCTAssertEqual(result, .calls(model.proposed))
        XCTAssertEqual(model.receivedPrompts, ["produce a cubic solid seven centimeters across"])
    }

    func testModelCannotInventNumbersOrUnsafeTools() async {
        let model = FakeAppleModel()
        let interpreter = CompositeInterpreter(model: AppleModelInterpreter(model: model), fallback: RuleBasedInterpreter())
        model.proposed = [ToolCall(name: "create_cube", arguments: ["size": .number(9), "unit": .string("cm")])]
        let invented = await interpreter.interpret(FinalUtterance(text: "produce a cubic solid seven centimeters across"), context: none)
        XCTAssertEqual(invented, .clarify(RuleBasedInterpreter.notACommand))
        model.proposed = [ToolCall(name: "delete_selected")]
        let unrelated = await interpreter.interpret(FinalUtterance(text: "produce a cubic solid seven centimeters across"), context: none)
        XCTAssertEqual(unrelated, .clarify(RuleBasedInterpreter.notACommand))
    }

    func testUnavailableAppleModelKeepsTheRuleFallback() async {
        let model = FakeAppleModel()
        model.available = false
        let interpreter = CompositeInterpreter(model: AppleModelInterpreter(model: model), fallback: RuleBasedInterpreter())
        let result = await interpreter.interpret(FinalUtterance(text: "produce a cubic solid seven centimeters across"), context: none)
        XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand))
        XCTAssertTrue(model.receivedPrompts.isEmpty)
    }

    func testCreativeRequestNeverBecomesAnUnrelatedModelTool() async {
        let model = FakeAppleModel()
        model.proposed = [ToolCall(name: "delete_selected")]
        let interpreter = CompositeInterpreter(model: AppleModelInterpreter(model: model), fallback: RuleBasedInterpreter())
        let result = await interpreter.interpret(FinalUtterance(text: "make a table"), context: none)
        XCTAssertEqual(result, .needsImagine)
        XCTAssertTrue(model.receivedPrompts.isEmpty)
    }
}
