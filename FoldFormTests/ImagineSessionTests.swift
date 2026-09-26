import XCTest
import simd
@testable import FoldForm

private actor TestImagineGenerator: ImagineGenerating {
    var result: Result<ImaginePlan, OpenAIImagineError>
    var waitsForReply: Bool
    private(set) var callCount = 0
    private(set) var lastRequest: ImagineRequest?
    private var continuation: CheckedContinuation<ImaginePlan, Error>?

    init(_ result: Result<ImaginePlan, OpenAIImagineError>, waitsForReply: Bool = false) {
        self.result = result
        self.waitsForReply = waitsForReply
    }

    func generate(_ request: ImagineRequest) async throws -> ImaginePlan {
        callCount += 1
        lastRequest = request
        if waitsForReply {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return try result.get()
    }

    func release() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class TestImagineQuota: ImagineUsageLimiting {
    var dailyLimit: Int
    private var ids = Set<UUID>()
    var remaining: Int { max(0, dailyLimit - ids.count) }
    init(limit: Int = 50) { dailyLimit = limit }
    func canGenerate() -> Bool { remaining > 0 }
    func recordGeneration(id: UUID) -> Bool {
        guard canGenerate(), ids.insert(id).inserted else { return false }
        return true
    }
}

@MainActor
final class ImagineSessionTests: XCTestCase {
    private var model: AppModel!
    private var viewport: ViewportEntities!
    private var executor: CADActionExecutor!
    private var plateCount: Int { model.document.partStudio.orderedBodyIDs.count }

    override func setUp() async throws {
        model = AppModel()
        viewport = ViewportEntities()
        viewport.update(appModel: model)
        executor = CADActionExecutor(appModel: model, viewport: viewport)
    }

    private func plan(_ steps: String) -> ImaginePlan {
        try! ImaginePlan.decode(Data("{\"steps\":\(steps)}".utf8))
    }

    private func session(_ generator: TestImagineGenerator, quota: TestImagineQuota = TestImagineQuota()) -> ImagineSession {
        ImagineSession(appModel: model, viewport: viewport, executor: executor, generator: generator, usageLimiter: quota)
    }

    private func meshes() -> [UUID: RenderMesh] {
        Dictionary(uniqueKeysWithValues: model.document.partStudio.orderedBodyIDs.map { id in (id, model.document.partStudio.body(id)!.mesh) })
    }

    private func generate(_ session: ImagineSession) async {
        await session.generate(prompt: "Add a small support", sketchPNG: Data([1, 2, 3]), polylines: [[[0, 0], [1, 1]]])
    }

    private func waitForCall(_ generator: TestImagineGenerator) async {
        for _ in 0..<200 {
            if await generator.callCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("generator was not called")
    }

    func testExhaustedQuotaStopsCloudCallAndShowsLimitState() async {
        let generator = TestImagineGenerator(.failure(.offline))
        let imagine = session(generator, quota: TestImagineQuota(limit: 0))
        await generate(imagine)
        let calls = await generator.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(imagine.phase, .limitReached)
    }

    func testLocalScriptedImagineRunsWhenCloudQuotaIsExhausted() async {
        let quota = TestImagineQuota(limit: 0)
        let imagine = ImagineSession(appModel: model, viewport: viewport, executor: executor,
                                     generator: HardcodedImagineGenerator(latency: .zero), usageLimiter: quota)
        await imagine.generate(prompt: "create a table", sketchPNG: Data(), polylines: [])
        guard case .done = imagine.phase else { return XCTFail("local demo should remain available") }
        XCTAssertEqual(plateCount, 6)
        XCTAssertEqual(quota.remaining, 0)
    }

    func testCloudAttemptUsesExactlyOneQuotaSlotEvenOnFailure() async {
        let generator = TestImagineGenerator(.failure(.offline))
        let quota = TestImagineQuota(limit: 3)
        let imagine = session(generator, quota: quota)
        await generate(imagine)
        XCTAssertEqual(quota.remaining, 2)
        let calls = await generator.callCount
        XCTAssertEqual(calls, 1)
    }

    func testGoodPlanAddsBodiesAndOneUndoRemovesBoth() async {
        let before = meshes()
        let generator = TestImagineGenerator(.success(plan(#"[{"as":"a","op":"add_box","args":{"width":20,"depth":20,"height":20,"unit":"mm"}},{"as":"b","op":"add_box","args":{"width":10,"depth":10,"height":10,"unit":"mm"}}]"#)))
        let imagine = session(generator)
        let callsBeforeGenerate = await generator.callCount
        XCTAssertEqual(callsBeforeGenerate, 0, "opening Imagine must not send anything")
        await generate(imagine)
        XCTAssertEqual(plateCount, before.count + 2)
        guard case .done(_, _) = imagine.phase else { return XCTFail("should report success") }
        XCTAssertEqual(viewport.aiHighlightIDs.count, 2)
        viewport.undo()
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo, "the plan is one undo step")
    }

    func testFailureAtThirdStepRollsBackAllBodiesAndAddsNoUndoEntry() async {
        let before = meshes()
        let generator = TestImagineGenerator(.success(plan(#"[{"as":"a","op":"add_box","args":{"width":20,"depth":20,"height":20,"unit":"mm"}},{"as":"b","op":"add_box","args":{"width":10,"depth":10,"height":10,"unit":"mm"}},{"op":"round","target":"a","args":{"radius":500,"unit":"mm"}}]"#)))
        let imagine = session(generator)
        await generate(imagine)
        XCTAssertEqual(meshes(), before)
        XCTAssertFalse(viewport.canUndo)
        guard case .failed = imagine.phase else { return XCTFail("failure must be visible") }
        XCTAssertTrue(viewport.aiHighlightIDs.isEmpty)
    }

    func testStaleReplyAfterDocumentEditIsRejected() async {
        let generator = TestImagineGenerator(.success(plan(#"[{"op":"add_box","args":{"width":20,"depth":20,"height":20,"unit":"mm"}}]"#)), waitsForReply: true)
        let imagine = session(generator)
        let task = Task { await generate(imagine) }
        await waitForCall(generator)
        XCTAssertNil(executor.run([.createCube(size: 0.01)]).failure)
        let afterEdit = meshes()
        await generator.release()
        await task.value
        XCTAssertEqual(meshes(), afterEdit)
        guard case .failed(let message) = imagine.phase else { return XCTFail("stale reply must fail") }
        XCTAssertTrue(message.contains("changed"))
    }

    func testExistingP1EditPreservesOtherBodies() async {
        XCTAssertNil(executor.run([.createCube(size: 0.02)]).failure)
        let ids = model.document.partStudio.orderedBodyIDs
        let beforePlate = model.document.partStudio.body(ids[0])!.mesh
        let beforeP1 = model.document.partStudio.body(ids[1])!.mesh
        let generator = TestImagineGenerator(.success(plan(#"[{"op":"move","target":"P1","args":{"x":10,"unit":"mm"}}]"#)))
        await generate(session(generator))
        XCTAssertEqual(model.document.partStudio.body(ids[0])!.mesh, beforePlate)
        XCTAssertNotEqual(model.document.partStudio.body(ids[1])!.mesh, beforeP1)
        XCTAssertEqual(plateCount, 2)
    }

    func testOfflineErrorKeepsTheDocument() async {
        let before = meshes()
        let imagine = session(TestImagineGenerator(.failure(.offline)))
        await generate(imagine)
        XCTAssertEqual(meshes(), before)
        guard case .failed(let message) = imagine.phase else { return XCTFail("offline must be visible") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("offline"))
    }

    func testCancelMidRequestAppliesNothing() async {
        let before = meshes()
        let generator = TestImagineGenerator(.success(plan(#"[{"op":"add_box","args":{"width":20,"depth":20,"height":20,"unit":"mm"}}]"#)), waitsForReply: true)
        let imagine = session(generator)
        let task = Task { await generate(imagine) }
        await waitForCall(generator)
        imagine.cancel()
        await generator.release()
        await task.value
        XCTAssertEqual(meshes(), before)
        XCTAssertEqual(imagine.phase, .idle)
    }

    func testRequestContainsHeadlessDesignImageAndSymbolicBodyList() async throws {
        XCTAssertNil(executor.run([.createCube(size: 0.02)]).failure)
        let generator = TestImagineGenerator(.success(plan("[]")))
        await generate(session(generator))
        let sentRequest = await generator.lastRequest
        let request = try XCTUnwrap(sentRequest)
        XCTAssertFalse(request.designPNG.isEmpty)
        XCTAssertTrue(request.designDescription.contains("P0:"))
        XCTAssertTrue(request.designDescription.contains("P1:"))
        XCTAssertEqual(request.revision, viewport.documentRevision)
    }

    func testRequestCarriesTheCurrentDisplayUnit() async throws {
        let generator = TestImagineGenerator(.success(plan("[]")))
        let imagine = session(generator)
        await imagine.generate(prompt: "Make a bracket", sketchPNG: Data([1]), polylines: [], units: "cm")
        let sentRequest = await generator.lastRequest
        XCTAssertEqual(sentRequest?.units, "cm")
    }

    func testNextEditClearsImagineHighlight() async {
        let generator = TestImagineGenerator(.success(plan(#"[{"op":"add_box","args":{"width":20,"depth":20,"height":20,"unit":"mm"}}]"#)))
        await generate(session(generator))
        XCTAssertEqual(viewport.aiHighlightIDs.count, 1)
        XCTAssertNil(executor.run([.createCube(size: 0.01)]).failure)
        XCTAssertTrue(viewport.aiHighlightIDs.isEmpty)
    }
}
