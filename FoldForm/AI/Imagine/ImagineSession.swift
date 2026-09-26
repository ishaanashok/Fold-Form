import Foundation
import SwiftUI
import simd

enum ImaginePhase: Equatable {
    case idle
    case readingSketch
    case planning
    case building(done: Int, total: Int)
    case done(summary: String, assumptions: [ImagineAssumption])
    case failed(String)
}

/// Captures the document at the instant Generate is pressed, then accepts only a plan for that
/// revision. Model output is validated before the executor sees it, and execution is atomic.
@MainActor
final class ImagineSession: ObservableObject {
    @Published private(set) var phase: ImaginePhase = .idle

    private let appModel: AppModel
    private let viewport: ViewportEntities
    private let executor: CADActionExecutor
    private let generator: any ImagineGenerating
    private var requestTask: Task<ImaginePlan, Error>?
    private var requestID: UUID?

    init(appModel: AppModel, viewport: ViewportEntities, executor: CADActionExecutor, generator: any ImagineGenerating) {
        self.appModel = appModel
        self.viewport = viewport
        self.executor = executor
        self.generator = generator
    }

    func generate(prompt: String, sketchPNG: Data, polylines: [[SIMD2<Float>]], allowDelete: Bool = false) async {
        guard requestTask == nil else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { phase = .failed("Describe what you want to make."); return }
        let id = UUID()
        requestID = id
        phase = .readingSketch
        await Task.yield()
        viewport.update(appModel: appModel)
        let bodyIDs = appModel.document.partStudio.orderedBodyIDs
        let bodies = bodyIDs.compactMap { id -> (id: UUID, mesh: RenderMesh)? in
            guard let body = appModel.document.partStudio.body(id) else { return nil }
            return (id, body.mesh)
        }
        let parts = bodies.compactMap(DesignScene.part(from:))
        guard !parts.isEmpty,
              let image = ThumbnailRenderer.render(bodies.map { .init(mesh: $0.mesh, rgb: ThumbnailRenderer.defaultRGB) })?.pngData() else {
            phase = .failed("The current design couldn't be captured. Try again.")
            requestID = nil
            return
        }
        let selected = viewport.selectedDocumentBodyID.flatMap { selected in
            bodyIDs.firstIndex(of: selected).map { "P\($0)" }
        }
        let revision = viewport.documentRevision
        let request = ImagineRequest(
            prompt: trimmed,
            sketchPNG: sketchPNG,
            polylines: polylines,
            designPNG: image,
            designDescription: DesignScene(parts: parts).description,
            selectedBody: selected,
            units: "mm",
            revision: revision,
            allowDelete: allowDelete
        )
        guard requestID == id else { return }
        phase = .planning
        let task = Task { try await generator.generate(request) }
        requestTask = task
        do {
            let plan = try await task.value
            guard requestID == id else { return }
            requestTask = nil
            let actions = try ImaginePlanValidator.validate(
                plan, bodyCount: bodyIDs.count, revision: revision,
                currentRevision: viewport.documentRevision, allowDelete: allowDelete
            )
            guard !actions.isEmpty else { phase = .failed("Imagine returned no changes. Try a more specific request."); requestID = nil; return }
            phase = .building(done: 0, total: actions.count)
            await Task.yield()
            guard requestID == id else { return }
            guard revision == viewport.documentRevision else { throw ImagineValidationError.staleRevision }
            let result = executor.runAtomically(actions)
            if let failure = result.failure {
                phase = .failed("No changes were applied. \(failure)")
            } else {
                let after = Set(appModel.document.partStudio.orderedBodyIDs)
                viewport.highlightAI(after.subtracting(bodyIDs))
                phase = .done(summary: "Built \(result.completed) \(result.completed == 1 ? "step" : "steps")", assumptions: plan.assumptions)
            }
            requestID = nil
        } catch {
            guard requestID == id else { return }
            requestTask = nil
            requestID = nil
            if let error = error as? ImagineValidationError { phase = .failed(error.message) }
            else if let error = error as? NIMError { phase = .failed(error.message) }
            else if !(error is CancellationError) { phase = .failed("Imagine couldn't finish. Try again.") }
        }
    }

    func cancel() {
        requestID = nil
        requestTask?.cancel()
        requestTask = nil
        phase = .idle
    }
}
