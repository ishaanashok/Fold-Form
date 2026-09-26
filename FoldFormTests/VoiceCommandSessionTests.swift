import XCTest
@testable import FoldForm

/// Actor used to hold an interpreter call open until the test says otherwise.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var waiting = false
    func wait() async {
        if isOpen { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}

private struct StubInterpreter: CommandInterpreter {
    var handler: @Sendable (FinalUtterance) async -> InterpretResult
    func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult { await handler(utterance) }
}

@MainActor
final class VoiceCommandSessionTests: XCTestCase {
    private var model: AppModel!
    private var viewport: ViewportEntities!
    private var executor: CADActionExecutor!
    private var speech: ScriptedSpeechService!

    override func setUp() async throws {
        model = AppModel()
        viewport = ViewportEntities()
        viewport.update(appModel: model)
        executor = CADActionExecutor(appModel: model, viewport: viewport)
        speech = ScriptedSpeechService()
    }

    private var bodyCount: Int { model.document.partStudio.orderedBodyIDs.count }

    private func makeSession(interpreter: CommandInterpreter = RuleBasedInterpreter(), display: Double = 30) -> VoiceCommandSession {
        let session = VoiceCommandSession(speech: speech, interpreter: interpreter, executor: executor,
                                          contextProvider: { [executor] in executor!.currentContext() })
        session.resultDisplayDuration = display
        return session
    }

    /// Lets the session's event loop and any interpreter work run.
    private func eventually(_ message: String = "condition", timeout: Double = 3, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(message)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    private func final(_ text: String, id: UUID = UUID()) -> SpeechEvent { .final(FinalUtterance(id: id, text: text)) }

    // MARK: Tests

    func testInterimTextNeverRunsACommand() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(.interim("make a 3 centimeter cube"))
        await eventually("interim shown") { session.phase == .listening("make a 3 centimeter cube") }
        await settle()
        XCTAssertEqual(bodyCount, before)
    }

    func testAFinalRunsTheInterpreterThenTheExecutor() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(final("make a 3 centimeter cube"))
        await eventually("cube made") { bodyCount == before + 1 }
        await eventually("done shown") { if case .done(let text) = session.phase { return text.contains("Create cube") } else { return false } }
    }

    func testABlankFinalDoesNothing() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(final("   "))
        await settle()
        XCTAssertEqual(bodyCount, before)
        XCTAssertEqual(session.phase, .listening(""))
    }

    func testCancelDropsALaterFinal() async {
        let session = makeSession()
        await session.start()
        await session.cancel()
        let before = bodyCount
        speech.emit(final("make a 3 centimeter cube"))
        await settle()
        XCTAssertEqual(bodyCount, before)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isActive)
    }

    func testAnOlderResultArrivingAfterANewerUtteranceStartedIsDropped() async {
        let gate = Gate()
        let interpreter = StubInterpreter { utterance in
            if utterance.text == "slow" {
                await gate.wait()
                return .calls([ToolCall(name: "create_cube", arguments: ["size": .number(50), "unit": .string("mm")])])
            }
            return .calls([ToolCall(name: "create_cube", arguments: ["size": .number(20), "unit": .string("mm")])])
        }
        let session = makeSession(interpreter: interpreter)
        await session.start()
        let before = bodyCount
        speech.emit(final("slow"))
        await eventually("slow one waiting") { session.phase == .interpreting("slow") }
        speech.emit(final("fast"))
        await eventually("fast one ran") { bodyCount == before + 1 }
        await gate.open()
        await settle()
        XCTAssertEqual(bodyCount, before + 1, "the older utterance must not run after a newer one")
    }

    func testTheSameUtteranceDeliveredTwiceRunsOnce() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        let id = UUID()
        speech.emit(final("make a 3 centimeter cube", id: id))
        speech.emit(final("make a 3 centimeter cube", id: id))
        await eventually("cube made") { bodyCount == before + 1 }
        await settle()
        XCTAssertEqual(bodyCount, before + 1)
    }

    func testAFailedStepShowsWhyAndKeepsEarlierSteps() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(final("make a 3 centimeter cube and round it by 500 millimeters"))
        await eventually("failure shown") { if case .failed = session.phase { return true } else { return false } }
        guard case .failed(let text, let message) = session.phase else { return XCTFail() }
        XCTAssertEqual(text, "make a 3 centimeter cube and round it by 500 millimeters")
        XCTAssertTrue(message.contains("too big"), message)
        XCTAssertEqual(bodyCount, before + 1, "the cube that was made is kept")
    }

    func testTheSessionKeepsListeningAfterACommandUntilStopped() async {
        let session = makeSession(display: 0.05)
        await session.start()
        let before = bodyCount
        speech.emit(final("make a 3 centimeter cube"))
        await eventually("cube made") { bodyCount == before + 1 }
        await eventually("back to listening") { session.phase == .listening("") }
        XCTAssertTrue(session.isActive)
        speech.emit(final("make a 2 centimeter cube"))
        await eventually("second cube") { bodyCount == before + 2 }
        await session.stop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isActive)
    }

    func testAQuestionChangesNothing() async {
        let session = makeSession()
        await session.start()
        viewport.select(documentBodyID: nil)
        let before = bodyCount
        speech.emit(final("move it 5 millimeters up"))
        await eventually("answer shown") { session.phase == .failed("move it 5 millimeters up", "Select a part first") }
        XCTAssertEqual(bodyCount, before)
        XCTAssertFalse(viewport.canUndo)
    }

    func testACreativeRequestIsPointedAtImagine() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(final("design a bracket with ventilation slots"))
        await eventually("pointed to Imagine") { session.phase == .failed("design a bracket with ventilation slots", "This request needs Imagine") }
        XCTAssertEqual(bodyCount, before)
    }

    func testAnUnavailableMicrophoneEndsTheSessionWithAReason() async {
        let session = makeSession()
        await session.start()
        speech.emit(.state(.unavailable("Microphone access is off")))
        await eventually("reason shown") { session.phase == .failed("", "Microphone access is off") }
        XCTAssertFalse(session.isActive)
    }

    func testAVoiceCommandIsOneUndoStep() async {
        let session = makeSession()
        await session.start()
        let before = bodyCount
        speech.emit(final("make a 3 centimeter cube and move it 2 centimeters to the right"))
        await eventually("both steps") { if case .done = session.phase { return true } else { return false } }
        viewport.undo()
        XCTAssertEqual(bodyCount, before)
        XCTAssertFalse(viewport.canUndo)
    }

    func testContextReflectsSelectionSketchAndHistory() {
        XCTAssertEqual(executor.currentContext().selection, .none)
        XCTAssertFalse(executor.currentContext().canUndo)
        XCTAssertFalse(executor.currentContext().canRedo)
        executor.run([.createCube(size: 0.03)])
        var context = executor.currentContext()
        XCTAssertEqual(context.selection, .box)
        XCTAssertTrue(context.canUndo)
        executor.run([.createCylinder(radius: 0.01, height: 0.02)])
        XCTAssertEqual(executor.currentContext().selection, .cylinder)
        executor.run([.rotate(target: .selected, axis: .z, angle: 0.5)])
        XCTAssertEqual(executor.currentContext().selection, .other)
        executor.run([.startSketch])
        context = executor.currentContext()
        XCTAssertTrue(context.isSketching)
    }
}
