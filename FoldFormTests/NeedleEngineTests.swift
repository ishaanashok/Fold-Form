import XCTest
@testable import FoldForm

/// Runs the real engine and weights. Skipped unless NEEDLE_MODEL_PATH (pass it as TEST_RUNNER_NEEDLE_MODEL_PATH)
/// points at needle3.cact, because the weights are not in the repository.
final class NeedleEngineTests: XCTestCase {
    private static let runtime = CactusNeedleRuntime()

    private func loadedRuntime() async throws -> CactusNeedleRuntime {
        guard let path = ProcessInfo.processInfo.environment["NEEDLE_MODEL_PATH"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("NEEDLE_MODEL_PATH not set")
        }
        try await Self.runtime.load(from: URL(fileURLWithPath: path))
        return Self.runtime
    }

    private func interpret(_ text: String, _ context: ToolContext, runtime: CactusNeedleRuntime) async -> InterpretResult {
        await CompositeInterpreter(needle: NeedleInterpreter(runtime: runtime), fallback: RuleBasedInterpreter())
            .interpret(FinalUtterance(text: text), context: context)
    }

    func testTheEngineAnswersWithJSON() async throws {
        let runtime = try await loadedRuntime()
        let context = ToolContext(isSketching: false, selection: .none, canUndo: false, canRedo: false)
        let tools = try JSONSerialization.data(withJSONObject: ToolCatalog.schema(for: context))
        let reply = try await runtime.generate(prompt: "make a cube that's 3 centimeters wide", toolsJSON: String(data: tools, encoding: .utf8)!)
        print("NEEDLE RAW: \(reply)")
        XCTAssertEqual(NeedleInterpreter(runtime: runtime).parse(reply), .calls([ToolCall(name: "create_cube", arguments: ["size": .number(3), "unit": .string("cm")])]))
    }

    func testFreePhrasingThroughTheCompositeNeverRunsAnUnrelatedTool() async throws {
        let runtime = try await loadedRuntime()
        let box = ToolContext(isSketching: false, selection: .box, canUndo: true, canRedo: true)
        let none = ToolContext(isSketching: false, selection: .none, canUndo: true, canRedo: false)
        let cases: [(String, ToolContext)] = [
            ("could you knock up a cube, three centimeters a side", none), ("I'd like a cylinder ten millimeters wide and thirty tall", none),
            ("shove it two centimeters to the left", box), ("get rid of it", box), ("bring that back", box),
            ("spin it forty five degrees", box), ("what's the weather like", none), ("play some music", box),
            ("make it 30 millimeters taller", box), ("drill a 5 millimeter hole", box),
        ]
        for (text, context) in cases {
            let started = Date()
            let result = await interpret(text, context, runtime: runtime)
            print("COMPOSITE [\(String(format: "%.2f", Date().timeIntervalSince(started)))s] \(text) -> \(result)")
            if case .calls(let calls) = result {
                XCTAssertNotNil(try? ToolCatalog.validateSequence(calls, context: context), text)
            }
        }
        // Sentences with nothing to do with CAD are never turned into an action.
        for text in ["what's the weather like", "play some music"] {
            let result = await interpret(text, box, runtime: runtime)
            XCTAssertEqual(result, .clarify(RuleBasedInterpreter.notACommand), text)
        }
    }
}
