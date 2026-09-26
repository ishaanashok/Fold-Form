import XCTest
@testable import FoldForm

final class ToolCatalogTests: XCTestCase {
    private let none = ToolContext()
    private let box = ToolContext(selection: .box)
    private let sketching = ToolContext(isSketching: true)

    private func call(_ name: String, _ args: [String: ToolValue] = [:]) -> ToolCall { ToolCall(name: name, arguments: args) }

    func testCubeInCentimetresBecomesMetres() throws {
        let action = try ToolCatalog.validate(call("create_cube", ["size": .number(3), "unit": .string("cm")]), context: none)
        guard case .createCube(let size, _, _) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(size, 0.03, accuracy: 1e-6)
    }

    func testThirtyMillimetresIsNotThreeCentimetresByMistake() throws {
        guard case .createCube(let a, _, _) = try ToolCatalog.validate(call("create_cube", ["size": .number(30), "unit": .string("mm")]), context: none),
              case .createCube(let b, _, _) = try ToolCatalog.validate(call("create_cube", ["size": .number(3), "unit": .string("cm")]), context: none)
        else { return XCTFail() }
        XCTAssertEqual(a, b, accuracy: 1e-6)
    }

    func testMissingUnitUsesTheContextDefault() throws {
        let cm = ToolContext(defaultUnit: "cm")
        guard case .createCube(let size, _, _) = try ToolCatalog.validate(call("create_cube", ["size": .number(4)]), context: cm) else { return XCTFail() }
        XCTAssertEqual(size, 0.04, accuracy: 1e-6)
    }

    func testMissingRequiredArgumentIsReported() {
        XCTAssertThrowsError(try ToolCatalog.validate(call("create_cube", ["unit": .string("cm")]), context: none)) {
            XCTAssertEqual($0 as? ToolError, .missing("size"))
        }
    }

    func testZeroNegativeUnknownUnitAndNonFiniteAreInvalid() {
        for bad: ToolValue in [.number(0), .number(-1), .number(.nan), .number(.infinity)] {
            XCTAssertThrowsError(try ToolCatalog.validate(call("create_cube", ["size": bad, "unit": .string("cm")]), context: none))
        }
        XCTAssertThrowsError(try ToolCatalog.validate(call("create_cube", ["size": .number(3), "unit": .string("parsecs")]), context: none))
    }

    func testAbsurdSizesAreRejected() {
        XCTAssertThrowsError(try ToolCatalog.validate(call("create_cube", ["size": .number(50), "unit": .string("m")]), context: none))
    }

    @MainActor func testExtrudeRangeMatchesTheSketchSlider() {
        XCTAssertEqual(ToolCatalog.extrudeRange, SketchController.depthRange)
    }

    func testUnknownToolIsRejected() {
        XCTAssertThrowsError(try ToolCatalog.validate(call("format_disk"), context: none)) {
            XCTAssertEqual($0 as? ToolError, .unknownTool("format_disk"))
        }
    }

    func testMoveNeedsASelection() {
        let move = call("move_selected", ["direction": .string("right"), "distance": .number(10), "unit": .string("mm")])
        XCTAssertThrowsError(try ToolCatalog.validate(move, context: none)) {
            XCTAssertEqual($0 as? ToolError, .notAvailable("Select a part first"))
        }
        guard case .move(.selected, .camera(let direction, let distance)) = try? ToolCatalog.validate(move, context: box) else { return XCTFail() }
        XCTAssertEqual(direction, .right)
        XCTAssertEqual(distance, 0.01, accuracy: 1e-6)
    }

    func testNegativeDistanceFlipsTheDirection() throws {
        let move = call("move_selected", ["direction": .string("right"), "distance": .number(-10), "unit": .string("mm")])
        guard case .move(_, .camera(let direction, let distance)) = try ToolCatalog.validate(move, context: box) else { return XCTFail() }
        XCTAssertEqual(direction, .left)
        XCTAssertEqual(distance, 0.01, accuracy: 1e-6)
    }

    func testExtrudeRangeAndCut() throws {
        let cut = call("extrude", ["distance": .number(2), "unit": .string("cm"), "operation": .string("cut")])
        guard case .extrude(let distance, let isCut) = try ToolCatalog.validate(cut, context: sketching) else { return XCTFail() }
        XCTAssertEqual(distance, 0.02, accuracy: 1e-6)
        XCTAssertTrue(isCut)
        XCTAssertThrowsError(try ToolCatalog.validate(call("extrude", ["distance": .number(500), "unit": .string("mm")]), context: sketching))
        XCTAssertThrowsError(try ToolCatalog.validate(call("extrude", ["distance": .number(0.5), "unit": .string("mm")]), context: sketching))
    }

    func testSketchToolsNeedASketch() {
        XCTAssertThrowsError(try ToolCatalog.validate(call("add_circle", ["radius": .number(12), "unit": .string("mm")]), context: none))
        XCTAssertNoThrow(try ToolCatalog.validate(call("add_circle", ["radius": .number(12), "unit": .string("mm")]), context: sketching))
    }

    func testCircleDiameterIsHalvedToARadius() throws {
        guard case .addCircle(let radius) = try ToolCatalog.validate(call("add_circle", ["diameter": .number(24), "unit": .string("mm")]), context: sketching) else { return XCTFail() }
        XCTAssertEqual(radius, 0.012, accuracy: 1e-6)
    }

    func testResizeAxisSynonymsAndRotatedBodies() throws {
        let taller = call("resize_selected", ["axis": .string("height"), "mode": .string("add"), "value": .number(2), "unit": .string("cm")])
        guard case .resize(_, let changes) = try ToolCatalog.validate(taller, context: box) else { return XCTFail() }
        XCTAssertEqual(changes, [DimensionChange(axis: .y, mode: .add, value: 0.02)])
        XCTAssertThrowsError(try ToolCatalog.validate(taller, context: ToolContext(selection: .other))) {
            XCTAssertEqual($0 as? ToolError, .notAvailable("This part can't be resized after rotating"))
        }
    }

    func testRotateDefaultsToDegreesAndAcceptsAxis() throws {
        guard case .rotate(_, let axis, let angle) = try ToolCatalog.validate(call("rotate_selected", ["angle": .number(45), "axis": .string("z")]), context: box) else { return XCTFail() }
        XCTAssertEqual(axis, .z)
        XCTAssertEqual(angle, .pi / 4, accuracy: 1e-5)
    }

    func testUndoAndRedoRespectAvailability() {
        XCTAssertThrowsError(try ToolCatalog.validate(call("undo"), context: ToolContext(canUndo: false)))
        XCTAssertNoThrow(try ToolCatalog.validate(call("undo"), context: ToolContext(canUndo: true)))
        XCTAssertThrowsError(try ToolCatalog.validate(call("redo"), context: ToolContext(canRedo: false)))
    }

    func testToolListChangesWithState() {
        let general = Set(ToolCatalog.tools(for: none).map(\.name))
        XCTAssertTrue(general.contains("create_cube"))
        XCTAssertFalse(general.contains("resize_selected"))
        XCTAssertFalse(general.contains("add_rectangle"))
        let sketchTools = Set(ToolCatalog.tools(for: sketching).map(\.name))
        XCTAssertTrue(sketchTools.contains("add_rectangle"))
        XCTAssertFalse(sketchTools.contains("start_sketch"))
        XCTAssertTrue(Set(ToolCatalog.tools(for: box).map(\.name)).contains("resize_selected"))
    }

    func testSchemaIsOpenAIFunctionFormat() throws {
        let schema = ToolCatalog.schema(for: box)
        XCTAssertFalse(schema.isEmpty)
        for tool in schema {
            XCTAssertEqual(tool["type"] as? String, "function")
            let function = try XCTUnwrap(tool["function"] as? [String: Any])
            XCTAssertNotNil(function["name"] as? String)
            XCTAssertNotNil(function["description"] as? String)
            let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["type"] as? String, "object")
        }
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: schema))
    }
}
