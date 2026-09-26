import Foundation
import Combine

enum Workbench: String, CaseIterable, Identifiable {
    case model = "Model", sketch = "Sketch", sheetMetal = "Sheet Metal", inspect = "Inspect"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .model: return "cube.transparent"
        case .sketch: return "pencil.and.outline"
        case .sheetMetal: return "rectangle.split.3x1"
        case .inspect: return "magnifyingglass"
        }
    }
}

enum ModelingTool: String, CaseIterable, Identifiable {
    case sketch = "Sketch", extrude = "Extrude", revolve = "Revolve", hole = "Hole"
    case fillet = "Fillet", chamfer = "Chamfer", shell = "Shell", pattern = "Pattern"
    case mirror = "Mirror", boolean = "Boolean", measure = "Measure"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sketch: return "pencil.and.outline"
        case .extrude: return "arrow.up.to.line"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .hole: return "circle.dotted"
        case .fillet: return "circle.dashed"
        case .chamfer: return "square.dashed"
        case .shell: return "cube.transparent"
        case .pattern: return "square.grid.3x3"
        case .mirror: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .boolean: return "circlebadge.2"
        case .measure: return "ruler"
        }
    }
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
    @Published var activeWorkbench: Workbench = .model { didSet { recalculateEngineeringState() } }
    @Published var activeTool: ModelingTool? = nil
    @Published private(set) var lastOperationMessage = "Ready"
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
        lastOperationMessage = "Sketch mode: draw a rectangle or circle on the front plane."
    }

    @Published var thickness: Double = 1.0 { didSet { recalculateEngineeringState() } }        // mm
    @Published var bendRadius: Double = 1.5 { didSet { recalculateEngineeringState() } }        // mm
    @Published var kFactor: Double = 0.44 { didSet { recalculateEngineeringState() } }
    @Published var legOneLength: Double = 40.0 { didSet { recalculateEngineeringState() } }     // mm
    @Published var legTwoLength: Double = 40.0 { didSet { recalculateEngineeringState() } }     // mm
    @Published private(set) var sheetMetalResult: SheetMetalCalculator.Result = .init(bendAllowance: 0, bendDeduction: 0, flatLength: 80)

    @Published var showOnboarding = true
    @Published private(set) var demoBendLimitRadians: Double = .pi / 2

    private var cancellables: Set<AnyCancellable> = []

    init(document: CADDocument = .demoSheetPlateDocument()) {
        self.document = document
        observeHingeAngle()
        collision.onCollisionBegan = { [weak self] in self?.haptics.playCollision() }
        collision.onMaxBendCrossed = { [weak self] in self?.haptics.playDemoBendLimit() }
        recalculateEngineeringState()
    }

    /// A model for a saved design: each saved body becomes a "Body n" feature, so the first is the
    /// plate and the rest are parts, exactly as the workbench builds them from any document.
    convenience init(loaded: LoadedDesign) {
        let meshes = loaded.meshes.enumerated().filter { !$0.element.positions.isEmpty }
        guard !meshes.isEmpty else { self.init(); return }
        let document = CADDocument()
        for (position, entry) in meshes.enumerated() {
            document.partStudio.featureTree.append(ViewportSolidFeature(name: "Body \(position + 1)", mesh: entry.element))
        }
        document.partStudio.regenerate()
        self.init(document: document)
        for (id, entry) in zip(document.partStudio.orderedBodyIDs, meshes) {
            if entry.offset < loaded.styles.count, let style = loaded.styles[entry.offset] { partStyles[id] = style }
        }
    }

    private func observeHingeAngle() {
        hingeInput.$bendAngleRadians
            .sink { [weak self] angle in
                Task { @MainActor in
                    self?.handleAngleChange(angle)
                }
            }
            .store(in: &cancellables)
    }

    private func handleAngleChange(_ angleRadians: Double) {
        recalculateEngineeringState(for: angleRadians)
        demo.update(
            angleDegrees: angleRadians * 180 / .pi,
            isSheetMetalWorkbenchActive: activeWorkbench == .sheetMetal,
            collisionActive: collisionIsActive,
            maxBendReached: collision.maxBendReached
        )
    }

    private func recalculateEngineeringState(for angleRadians: Double? = nil) {
        let angle = angleRadians ?? hingeInput.bendAngleRadians
        demoBendLimitRadians = SheetMetalCalculator.demoBendLimitRadians(bendRadius: bendRadius, thickness: thickness)
        let calc = SheetMetalCalculator(thickness: thickness, insideBendRadius: bendRadius, kFactor: kFactor, legOneLength: legOneLength, legTwoLength: legTwoLength)
        sheetMetalResult = calc.calculate(bendAngleRadians: angle)

        collision.evaluateMaxBend(currentAngleRadians: angle, limitRadians: demoBendLimitRadians)
        collision.evaluateDemoObstacle(currentAngleRadians: angle)
    }

    var collisionIsActive: Bool {
        if case .active = collision.state { return true }
        return false
    }

    /// RealityKit reports these through the viewport, while the manager remains framework-free.
    func reportCollisionBegan() {
        collision.realityCollisionBegan(atAngleDegrees: hingeInput.bendAngleDegrees)
    }

    func reportCollisionEnded() {
        collision.realityCollisionEnded()
    }

    /// Persists geometry created by the direct viewport sketcher in the same Part Studio that the
    /// feature tree and inspector observe. The bridge intentionally preserves the evaluated mesh
    /// while the procedural kernel grows support for more sketch/feature combinations.
    /// Everything that makes up the document's content, for the viewport's undo stack.
    struct DocumentSnapshot {
        let partStudio: PartStudio
        let features: [any Feature]
        let profile: PartProfileKind
        let styles: [UUID: PartStyle]
    }

    /// Colours by document body. Bodies without one show in the default blue.
    @Published private(set) var partStyles: [UUID: PartStyle] = [:]

    func setStyles(_ styles: [UUID: PartStyle]) {
        partStyles.merge(styles) { _, new in new }
    }

    func snapshotDocument() -> DocumentSnapshot {
        DocumentSnapshot(
            partStudio: document.partStudio,
            features: document.partStudio.featureTree.features,
            profile: selectedProfile,
            styles: partStyles
        )
    }

    func restoreDocument(_ snapshot: DocumentSnapshot) {
        if document.partStudio !== snapshot.partStudio { document.partStudio = snapshot.partStudio }
        selectedProfile = snapshot.profile
        partStyles = snapshot.styles
        document.partStudio.featureTree.restore(snapshot.features)
        document.partStudio.regenerate()
        selection.clear()
        lastOperationMessage = "Undid the last action."
    }

    @discardableResult
    func addViewportSolids(_ meshes: [RenderMesh]) -> [UUID] {
        let baseIndex = document.partStudio.featureTree.features.count + 1
        for (index, mesh) in meshes.enumerated() {
            document.partStudio.featureTree.append(ViewportSolidFeature(
                name: "Extrude\(baseIndex + index)",
                mesh: mesh
            ))
        }
        document.partStudio.regenerate()
        lastOperationMessage = meshes.isEmpty ? lastOperationMessage : "Viewport extrusion added to Part Studio history."
        return document.partStudio.orderedBodyIDs.suffix(meshes.count)
            .map { $0 }
    }

    /// Removes material: each cutter is subtracted from the bodies it overlaps.
    func addViewportCuts(_ cutters: [RenderMesh]) {
        let baseIndex = document.partStudio.featureTree.features.count + 1
        for (index, cutter) in cutters.enumerated() {
            document.partStudio.featureTree.append(ViewportCutFeature(name: "Cut\(baseIndex + index)", cutter: cutter))
        }
        document.partStudio.regenerate()
        if !cutters.isEmpty { lastOperationMessage = "Viewport cut added to Part Studio history." }
    }

    /// Records touch-up results as features so they regenerate, and undo, like any other edit.
    func applyTouchUp(_ meshes: [UUID: RenderMesh]) {
        for (id, mesh) in meshes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            document.partStudio.featureTree.append(ViewportTouchUpFeature(
                name: "TouchUp\(document.partStudio.featureTree.features.count + 1)",
                targetBodyID: id,
                mesh: mesh
            ))
        }
        document.partStudio.regenerate()
        if !meshes.isEmpty { lastOperationMessage = "Touch up smoothed \(meshes.count) body(ies)." }
    }

    /// Adds finishing bodies (a table's aprons) and colours new and existing bodies.
    func applyFinish(styles: [UUID: PartStyle], additions: [(mesh: RenderMesh, style: PartStyle?)]) {
        setStyles(styles)
        guard !additions.isEmpty else { return }
        let ids = addViewportSolids(additions.map(\.mesh))
        for (id, addition) in zip(ids, additions) { if let style = addition.style { partStyles[id] = style } }
    }

    func reportExportFailure(_ error: Error) {
        lastOperationMessage = "Couldn't write the export file: \(error.localizedDescription)"
    }

    /// Back to the very first flat plate: every extra body, feature and selection is dropped.
    func resetDocumentToInitialPlate() {
        partStyles = [:]
        selectedProfile = .sheetPlate
        document.loadQuickStartProfile(.sheetPlate)
        selection.clear()
        activeTool = nil
        lastOperationMessage = "Reset to the initial plate."
    }

    @discardableResult
    func removeViewportSolid(bodyID: UUID) -> Bool {
        guard document.partStudio.orderedBodyIDs.dropFirst().contains(bodyID) else { return false }
        let owned = document.partStudio.featureTree.features.filter { $0.resultBodyID == bodyID }
        guard let feature = owned.first else { return false }
        for item in owned { document.partStudio.featureTree.remove(id: item.id) }
        document.partStudio.regenerate()
        lastOperationMessage = "Removed \(feature.name) from Part Studio history."
        return true
    }

    func startDemo() {
        hingeInput.reset()
        collision.reset()
        showOnboarding = true
        demo.start()
    }

    func selectProfile(_ profile: PartProfileKind) {
        guard selectedProfile != profile else { return }
        selectedProfile = profile
        document.loadQuickStartProfile(profile)
        hingeInput.reset()
        collision.reset()
        recalculateEngineeringState()
        lastOperationMessage = "Loaded " + profile.rawValue + " quick-start geometry."
    }

    func activate(_ tool: ModelingTool) {
        activeTool = tool
        switch tool {
        case .sketch:
            beginSketching()
        case .extrude:
            addExtrudeFromActiveSketch()
        case .hole:
            addHoleToLastBody()
        case .revolve, .fillet, .chamfer, .shell, .pattern, .mirror, .boolean, .measure:
            let feature = UnimplementedFeature(name: tool.rawValue + "1", label: tool.rawValue, targetBodyID: document.partStudio.orderedBodyIDs.last)
            document.partStudio.featureTree.append(feature)
            document.partStudio.regenerate()
            lastOperationMessage = tool.rawValue + " is preserved in history and reports its kernel limitation."
        }
    }

    private func addExtrudeFromActiveSketch() {
        guard let sketch = document.partStudio.featureTree.sketches.last else {
            lastOperationMessage = "Create a sketch before extruding."
            return
        }
        guard (try? sketch.resolveClosedProfile()) != nil else {
            lastOperationMessage = "Extrude needs a valid closed profile."
            return
        }
        let alreadyExists = document.partStudio.featureTree.features.contains {
            ($0 as? ExtrudeFeature)?.sketchID == sketch.id
        }
        guard !alreadyExists else {
            lastOperationMessage = sketch.name + " already has an Extrude feature."
            return
        }
        document.partStudio.featureTree.append(ExtrudeFeature(
            name: "Extrude" + String(document.partStudio.featureTree.features.count + 1),
            sketchID: sketch.id,
            parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new)
        ))
        document.partStudio.regenerate()
        lastOperationMessage = "Extrude added to the feature history."
    }

    private func addHoleToLastBody() {
        guard let bodyID = document.partStudio.orderedBodyIDs.last else {
            lastOperationMessage = "Create a solid before adding a hole."
            return
        }
        let alreadyExists = document.partStudio.featureTree.features.contains {
            ($0 as? HoleFeature)?.targetBodyID == bodyID
        }
        guard !alreadyExists else {
            lastOperationMessage = "A hole already exists on the active body."
            return
        }
        document.partStudio.featureTree.append(HoleFeature(
            name: "Hole" + String(document.partStudio.featureTree.features.count + 1),
            targetBodyID: bodyID,
            definition: HoleDefinition(center: .zero, diameter: 0.02)
        ))
        document.partStudio.regenerate()
        lastOperationMessage = "Through-hole added to the active body."
    }
}
