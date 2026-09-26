import XCTest
@testable import FoldForm

final class ImagineTests: XCTestCase {
    private func plan(_ json: String) throws -> ImaginePlan {
        try ImaginePlan.decode(Data(json.utf8))
    }

    private func validate(_ json: String, bodyCount: Int = 2, revision: Int = 4, currentRevision: Int = 4, allowDelete: Bool = false) throws -> [CADAction] {
        try ImaginePlanValidator.validate(plan(json), bodyCount: bodyCount, revision: revision, currentRevision: currentRevision, allowDelete: allowDelete)
    }

    func testValidDeltaConvertsDimensionsAndReferencesInOrder() throws {
        let actions = try validate("""
        {"assumptions":[{"name":"wall thickness","value":"4","unit":"mm"}],"steps":[
          {"as":"tab","op":"add_box","args":{"width":30,"depth":4,"height":20,"unit":"mm"}},
          {"op":"move","target":"tab","args":{"x":10,"y":0,"z":0,"unit":"mm"}},
          {"op":"round","target":"P1","args":{"radius":2,"unit":"mm"}}
        ]}
        """)
        XCTAssertEqual(actions.count, 3)
        guard case .createBox(let width, let depth, let height, .beside, "tab") = actions[0] else { return XCTFail("first step must create the named box") }
        XCTAssertEqual(width, 0.03, accuracy: 1e-7)
        XCTAssertEqual(depth, 0.004, accuracy: 1e-7)
        XCTAssertEqual(height, 0.02, accuracy: 1e-7)
        guard case .move(.named("tab"), .world(let offset)) = actions[1] else { return XCTFail("second step must move the new box") }
        XCTAssertEqual(offset.x, 0.01, accuracy: 1e-7)
        XCTAssertEqual(offset.y, 0)
        XCTAssertEqual(offset.z, 0)
        XCTAssertEqual(actions[2], .round(target: .existing(1), radius: 0.002))
    }

    func testCodeFenceAndUnknownFieldsDecodeWhilePreservingAssumptions() throws {
        let result = try plan("""
        ```json
        {"assumptions":[{"name":"width","value":"75","unit":"mm","ignored":true}],"steps":[],"unused":"ok"}
        ```
        """)
        XCTAssertEqual(result.assumptions, [.init(name: "width", value: "75", unit: "mm")])
        XCTAssertTrue(result.steps.isEmpty)
    }

    func testUnknownOperationIsRejected() throws {
        XCTAssertThrowsError(try validate(#"{"steps":[{"op":"teleport","args":{}}]}"#)) {
            XCTAssertEqual($0 as? ImagineValidationError, .unknownOperation("teleport"))
        }
    }

    func testMissingAndBadUnitsAreRejected() throws {
        XCTAssertThrowsError(try validate(#"{"steps":[{"op":"add_box","args":{"width":3,"depth":4,"unit":"mm"}}]}"#)) {
            XCTAssertEqual($0 as? ImagineValidationError, .missing("height"))
        }
        XCTAssertThrowsError(try validate(#"{"steps":[{"op":"add_box","args":{"width":3,"depth":4,"height":5,"unit":"pixels"}}]}"#)) {
            XCTAssertEqual($0 as? ImagineValidationError, .badUnit("pixels"))
        }
    }

    func testNonFiniteNegativeAndHugeDimensionsAreRejected() throws {
        for value in [Double.nan, .infinity, -1, 0, 1_000_000] {
            let step = ImagineStep(as: nil, op: "add_box", args: ["width": .number(value), "depth": .number(4), "height": .number(5), "unit": .string("mm")], target: nil)
            let plan = ImaginePlan(assumptions: [], steps: [step])
            XCTAssertThrowsError(try ImaginePlanValidator.validate(plan, bodyCount: 2, revision: 4, currentRevision: 4, allowDelete: false), "\(value)")
        }
    }

    func testForwardAndUnknownReferencesAreRejected() throws {
        let forward = #"{"steps":[{"op":"move","target":"later","args":{"x":1,"unit":"mm"}},{"as":"later","op":"add_box","args":{"width":2,"depth":2,"height":2,"unit":"mm"}}]}"#
        XCTAssertThrowsError(try validate(forward)) {
            XCTAssertEqual($0 as? ImagineValidationError, .forwardReference("later"))
        }
        let unknown = #"{"steps":[{"op":"round","target":"P9","args":{"radius":1,"unit":"mm"}}]}"#
        XCTAssertThrowsError(try validate(unknown)) {
            XCTAssertEqual($0 as? ImagineValidationError, .unknownReference("P9"))
        }
    }

    func testMoreThanTwelveStepsAreRejected() throws {
        let steps = Array(repeating: ImagineStep(as: nil, op: "add_box", args: ["width": .number(2), "depth": .number(2), "height": .number(2), "unit": .string("mm")], target: nil), count: 13)
        XCTAssertThrowsError(try ImaginePlanValidator.validate(.init(assumptions: [], steps: steps), bodyCount: 2, revision: 4, currentRevision: 4, allowDelete: false)) {
            XCTAssertEqual($0 as? ImagineValidationError, .tooManySteps)
        }
    }

    func testStaleRevisionRejectsThePlanBeforeApplyingIt() throws {
        XCTAssertThrowsError(try validate(#"{"steps":[]}"#, revision: 4, currentRevision: 5)) {
            XCTAssertEqual($0 as? ImagineValidationError, .staleRevision)
        }
    }

    func testDeleteRequiresPermissionAndNeverDeletesTheBasePlate() throws {
        let step = #"{"steps":[{"op":"delete","target":"P1","args":{}}]}"#
        XCTAssertThrowsError(try validate(step)) {
            XCTAssertEqual($0 as? ImagineValidationError, .forbiddenDelete)
        }
        XCTAssertEqual(try validate(step, allowDelete: true), [.delete(target: .existing(1))])
        let plate = #"{"steps":[{"op":"delete","target":"P0","args":{}}]}"#
        XCTAssertThrowsError(try validate(plate, allowDelete: true)) {
            XCTAssertEqual($0 as? ImagineValidationError, .basePlateDelete)
        }
    }

    func testExtrudeProfileUsesValidatedOutlineAndDepth() throws {
        let actions = try validate(#"{"steps":[{"as":"backrest","op":"extrude_profile","args":{"outline":[[0,0],[40,0],[40,60],[0,60]],"depth":4,"unit":"mm"}}]}"#)
        XCTAssertEqual(actions.count, 1)
        guard case .createPrism(let outline, let depth, .beside, "backrest") = actions[0] else { return XCTFail("profile must be a prism") }
        XCTAssertEqual(outline.count, 4)
        XCTAssertEqual(outline[1].x, 0.04, accuracy: 1e-7)
        XCTAssertEqual(outline[2].y, 0.06, accuracy: 1e-7)
        XCTAssertEqual(depth, 0.004, accuracy: 1e-7)
    }
}
