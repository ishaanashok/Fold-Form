import Foundation
import Combine

enum Workbench: String, CaseIterable, Identifiable {
    case model = "Model", sketch = "Sketch", sheetMetal = "Sheet Metal", inspect = "Inspect"
    var id: String { rawValue }
}

enum ModelingTool: String, CaseIterable, Identifiable {
    case sketch = "Sketch", extrude = "Extrude", revolve = "Revolve", hole = "Hole"
    case fillet = "Fillet", chamfer = "Chamfer", shell = "Shell", pattern = "Pattern"
    case mirror = "Mirror", boolean = "Boolean", measure = "Measure"
    var id: String { rawValue }
}

/// The single source of truth (plan section 5). Hinge input, the bend deformer, the sheet-metal
/// calculator, collision, haptics, and every view read from and act through this model rather than
/// reaching directly into one another.
@MainActor
final class AppModel: ObservableObject {
    let document: CADDocument
    let hingeInput = HingeInputManager()
    let collision = CollisionManager()
    let selection = SelectionManager()
    let demo = DemoCoordinator()
    private let haptics = HapticManager()

    @Published var selectedProfile: PartProfileKind = .sheetPlate
    @Published var activeWorkbench: Workbench = .model
    @Published var activeTool: ModelingTool? = nil
    @Published var isSketchEditing = false
    @Published var activeSketchPlaneID: UUID?
    @Published var activeSketchID: UUID?

    /// Starts editing an existing sketch, or authors a new one on the first standard plane if none
    /// exists yet, so tapping the Sketch tool always has somewhere to draw.
    func beginSketching() {
        if let existing = document.partStudio.featureTree.sketches.last {
            activeSketchID = existing.id
        } else if let plane = document.partStudio.featureTree.referencePlanes.first {
            let sketch = Sketch(name: "Sketch\(document.partStudio.featureTree.sketches.count + 1)", planeID: plane.id)
            document.partStudio.featureTree.addSketch(sketch)
            document.partStudio.featureTree.append(SketchTreeFeature(name: sketch.name, sketchID: sketch.id))
            activeSketchID = sketch.id
        }
        isSketchEditing = true
    }

    @Published var thickness: Double = 1.0        // mm
    @Published var bendRadius: Double = 1.5        // mm
    @Published var kFactor: Double = 0.44
    @Published var legOneLength: Double = 40.0     // mm
    @Published var legTwoLength: Double = 40.0     // mm
    @Published private(set) var sheetMetalResult: SheetMetalCalculator.Result = .init(bendAllowance: 0, bendDeduction: 0, flatLength: 80)

    @Published var showOnboarding = true
    @Published private(set) var demoBendLimitRadians: Double = .pi / 2

    private var cancellables: Set<AnyCancellable> = []

    init(document: CADDocument = .demoSheetPlateDocument()) {
        self.document = document
        observeHingeAngle()
        collision.onMaxBendCrossed = { [weak self] in self?.haptics.playDemoBendLimit() }
    }

    private func observeHingeAngle() {
        hingeInput.$hingeAngleRadians
            .sink { [weak self] angle in
                self?.handleAngleChange(angle)
            }
            .store(in: &cancellables)
    }

    private func handleAngleChange(_ angleRadians: Double) {
        demoBendLimitRadians = SheetMetalCalculator.demoBendLimitRadians(bendRadius: bendRadius, thickness: thickness)
        let calc = SheetMetalCalculator(thickness: thickness, insideBendRadius: bendRadius, kFactor: kFactor, legOneLength: legOneLength, legTwoLength: legTwoLength)
        sheetMetalResult = calc.calculate(bendAngleRadians: angleRadians)

        collision.evaluateMaxBend(currentAngleRadians: angleRadians, limitRadians: demoBendLimitRadians)
        demo.update(
            angleDegrees: angleRadians * 180 / .pi,
            isSheetMetalWorkbenchActive: activeWorkbench == .sheetMetal,
            collisionActive: collisionIsActive,
            maxBendReached: collision.maxBendReached
        )
    }

    var collisionIsActive: Bool {
        if case .active = collision.state { return true }
        return false
    }

    /// Called by RealityViewport's CollisionEvents subscription (RealityKit-specific code lives
    /// there; this keeps AppModel free of RealityKit types for testability).
    func reportCollisionBegan() {
        collision.began(atAngleDegrees: hingeInput.hingeAngleDegrees)
        haptics.playCollision()
    }

    func reportCollisionEnded() {
        collision.ended()
    }

    func startDemo() {
        hingeInput.reset()
        collision.reset()
        demo.start()
    }
}
