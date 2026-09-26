import XCTest
@testable import FoldForm

/// The product spec's own example phrases, run through the interpreter and then through the same
/// validation the executor relies on. `summary` rounds to 0.1 mm, so these read as spoken.
final class RuleBasedInterpreterTests: XCTestCase {
    private let none = ToolContext(defaultUnit: "cm")
    private let box = ToolContext(selection: .box, defaultUnit: "cm")
    private let sketching = ToolContext(isSketching: true, defaultUnit: "cm")

    private func summaries(_ text: String, _ context: ToolContext, file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        guard case .calls(let calls) = RuleBasedInterpreter.parse(text, context: context) else {
            XCTFail("expected calls for: \(text) — got \(RuleBasedInterpreter.parse(text, context: context))", file: file, line: line)
            return nil
        }
        do {
            return try ToolCatalog.validateSequence(calls, context: context).map(\.summary)
        } catch {
            XCTFail("validation failed for: \(text) — \(error)", file: file, line: line)
            return nil
        }
    }

    private func result(_ text: String, _ context: ToolContext) -> InterpretResult { RuleBasedInterpreter.parse(text, context: context) }

    // MARK: Creating

    func testCubes() {
        XCTAssertEqual(summaries("Make a 3 centimeter cube.", none), ["Create cube · 30 mm"])
        XCTAssertEqual(summaries("Create a cube that's three centimeters wide", none), ["Create cube · 30 mm"])
        XCTAssertEqual(summaries("make a 30 millimeter cube", none), ["Create cube · 30 mm"])
        XCTAssertEqual(summaries("make a 3 cm cube", none), ["Create cube · 30 mm"])
        XCTAssertEqual(summaries("make a 3 mm cube", none), ["Create cube · 3 mm"])
        XCTAssertEqual(summaries("create a 2.5 centimeter cube", none), ["Create cube · 25 mm"])
        XCTAssertEqual(summaries("create a two point five centimeter cube", none), ["Create cube · 25 mm"])
    }

    func testBoxes() {
        XCTAssertEqual(summaries("Create a box 20 by 40 by 5 millimeters.", none), ["Create box · 20 mm × 40 mm × 5 mm"])
        XCTAssertEqual(summaries("create a box 2 by 4 by 1 centimeters", none), ["Create box · 20 mm × 40 mm × 10 mm"])
        XCTAssertEqual(summaries("make a box twenty by forty by five millimeters", none), ["Create box · 20 mm × 40 mm × 5 mm"])
    }

    func testCylinders() {
        XCTAssertEqual(summaries("create a cylinder with a radius of 12 millimeters and a height of 30 millimeters", none),
                       ["Create cylinder · r 12 mm × 30 mm"])
        XCTAssertEqual(summaries("make a cylinder 20 millimeters in diameter and 50 millimeters tall", none),
                       ["Create cylinder · r 10 mm × 50 mm"])
    }

    // MARK: Sketching

    func testCircleWhileSketching() {
        XCTAssertEqual(summaries("Make a circle with a radius of 12 millimeters.", sketching), ["Circle · r 12 mm"])
        XCTAssertEqual(summaries("add a circle with a diameter of 24 millimeters", sketching), ["Circle · r 12 mm"])
    }

    func testShapesStartASketchWhenNotSketching() {
        XCTAssertEqual(summaries("make a circle with a radius of 12 millimeters", none), ["Start sketch", "Circle · r 12 mm"])
    }

    func testCompoundRectangleAndExtrude() {
        XCTAssertEqual(summaries("Create a 4 by 6 centimeter rectangle and extrude it 2 centimeters.", none),
                       ["Start sketch", "Rectangle · 40 mm × 60 mm", "Extrude · 20 mm"])
        XCTAssertEqual(summaries("draw a 4 by 6 centimeter rectangle then extrude it by 2 centimeters", sketching),
                       ["Rectangle · 40 mm × 60 mm", "Extrude · 20 mm"])
    }

    func testExtrudeAndCut() {
        XCTAssertEqual(summaries("Extrude this by 2 centimeters.", sketching), ["Extrude · 20 mm"])
        XCTAssertEqual(summaries("cut 5 millimeters", sketching), ["Cut · 5 mm"])
        XCTAssertEqual(summaries("extrude cut 5 millimeters", sketching), ["Cut · 5 mm"])
        XCTAssertEqual(result("extrude this by 2 centimeters", none), .clarify("Start a sketch first"))
    }

    func testStartAndFinishSketch() {
        XCTAssertEqual(summaries("start a sketch", none), ["Start sketch"])
        XCTAssertEqual(summaries("finish the sketch", sketching), ["Finish sketch"])
    }

    // MARK: Editing the selection

    func testMoveRight() {
        XCTAssertEqual(summaries("Move this 10 millimeters to the right.", box), ["Move right · 10 mm"])
        XCTAssertEqual(summaries("move it two centimeters to the right", box), ["Move right · 20 mm"])
        XCTAssertEqual(summaries("move it 5 millimeters up", box), ["Move up · 5 mm"])
        XCTAssertEqual(summaries("move this 1 centimeter left", box), ["Move left · 10 mm"])
    }

    func testNegativeMoveFlipsDirection() {
        XCTAssertEqual(summaries("move it minus 10 millimeters to the right", box), ["Move left · 10 mm"])
        XCTAssertEqual(summaries("move it negative 2 centimeters up", box), ["Move down · 20 mm"])
    }

    func testMoveNeedsDirectionAndDistance() {
        XCTAssertEqual(result("move it 10 millimeters", box), .clarify("Which direction?"))
        XCTAssertEqual(result("move it to the right", box), .clarify("How far?"))
    }

    func testRotate() {
        XCTAssertEqual(summaries("Rotate this 45 degrees around Z.", box), ["Rotate · 45° about z"])
        XCTAssertEqual(summaries("rotate this 90 degrees", box), ["Rotate · 90° about y"])
        XCTAssertEqual(summaries("turn it forty five degrees about the x axis", box), ["Rotate · 45° about x"])
    }

    func testUndoAndRedo() {
        XCTAssertEqual(summaries("Undo that.", none), ["Undo"])
        XCTAssertEqual(summaries("undo", none), ["Undo"])
        XCTAssertEqual(summaries("redo", none), ["Redo"])
    }

    func testResizeWithComparatives() {
        XCTAssertEqual(summaries("Make this box 2 centimeters taller.", box), ["Resize · +20 mm y"])
        XCTAssertEqual(summaries("make it 5 millimeters thicker", box), ["Resize · +5 mm thinnest"])
        XCTAssertEqual(summaries("make this 1 centimeter shorter", box), ["Resize · -10 mm y"])
        XCTAssertEqual(summaries("make it 3 millimeters wider", box), ["Resize · +3 mm x"])
    }

    func testResizeToAnAbsoluteSize() {
        XCTAssertEqual(summaries("make this extrusion 15 millimeters deep", box), ["Resize · 15 mm z"])
        XCTAssertEqual(summaries("make this 40 millimeters wide", box), ["Resize · 40 mm x"])
        XCTAssertEqual(summaries("set the height to 3 centimeters", box), ["Resize · 30 mm y"])
    }

    func testRoundAndHole() {
        XCTAssertEqual(summaries("Round these edges by 2 millimeters.", box), ["Round · 2 mm"])
        XCTAssertEqual(summaries("fillet this 3 millimeters", box), ["Round · 3 mm"])
        XCTAssertEqual(summaries("Add a 5 millimeter hole on this face.", box), ["Hole · Ø 5 mm"])
        XCTAssertEqual(summaries("drill a 6 millimeter hole", box), ["Hole · Ø 6 mm"])
    }

    func testDuplicateAndDelete() {
        XCTAssertEqual(summaries("duplicate this", box), ["Duplicate"])
        XCTAssertEqual(summaries("delete this", box), ["Delete"])
    }

    func testCompoundOnASelectedPart() {
        XCTAssertEqual(summaries("rotate this 90 degrees and move it 5 millimeters up", box), ["Rotate · 90° about y", "Move up · 5 mm"])
    }

    func testCreateThenMoveInOneSentence() {
        XCTAssertEqual(summaries("create a 3 centimeter cube and move it 2 centimeters to the right", none),
                       ["Create cube · 30 mm", "Move right · 20 mm"])
    }

    // MARK: Things that must not happen

    func testEditsWithNothingSelectedAskForASelection() {
        XCTAssertEqual(result("Fillet that.", none), .clarify("Select a part first"))
        XCTAssertEqual(result("move this 5 millimeters up", none), .clarify("Select a part first"))
        XCTAssertEqual(result("rotate this 30 degrees", none), .clarify("Select a part first"))
        XCTAssertEqual(result("delete this", none), .clarify("Select a part first"))
    }

    func testNegationDoesNothing() {
        XCTAssertEqual(result("do not move it", box), .clarify("Nothing to do"))
        XCTAssertEqual(result("don't create a cube", none), .clarify("Nothing to do"))
    }

    func testChamferIsExplainedNotFaked() {
        guard case .clarify(let message) = result("chamfer this by 2 millimeters", box) else { return XCTFail() }
        XCTAssertTrue(message.lowercased().contains("chamfer"))
    }

    func testGenerativeRequestsNeedImagine() {
        XCTAssertEqual(result("Turn this into a phone stand with a fifteen degree backrest", none), .needsImagine)
        XCTAssertEqual(result("design a bracket with ventilation slots", none), .needsImagine)
        XCTAssertEqual(result("add a handle here", box), .needsImagine)
    }

    func testGibberishIsNotACommand() {
        XCTAssertEqual(result("the weather is nice today", none), .clarify("I didn't catch a command"))
        XCTAssertEqual(result("", none), .clarify("I didn't catch a command"))
    }

    func testChangingAnExistingHoleIsExplained() {
        guard case .clarify(let message) = result("make this hole 8 millimeters wider", box) else { return XCTFail() }
        XCTAssertTrue(message.lowercased().contains("hole"))
    }

    func testFinalUtteranceIsTheOnlyInput() async {
        let utterance = FinalUtterance(text: "make a 3 centimeter cube")
        let result = await RuleBasedInterpreter().interpret(utterance, context: none)
        XCTAssertEqual(result, RuleBasedInterpreter.parse("make a 3 centimeter cube", context: none))
    }
}
