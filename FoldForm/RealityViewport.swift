import SwiftUI
import RealityKit
import Combine
import UIKit

/// The pop-up shown by pressing and holding: on a part, or on empty space.
struct PartMenu: Equatable {
    var partID: UUID?
    var point: CGPoint
}

/// Progress of a touch up, for the button and the banner.
enum TouchUpStatus: Equatable {
    case idle, working
    case message(String)
}

/// One press of a cube arrow.
enum ViewStep: CaseIterable {
    case up, down, left, right, rollClockwise, rollCounterClockwise

    var isRoll: Bool { self == .rollClockwise || self == .rollCounterClockwise }

    /// Quarter turns, right-handed about `axis(of:)`. Right/left/up/down match a drag in that
    /// direction; a clockwise roll turns the picture clockwise on screen.
    var angle: Float {
        switch self {
        case .up, .left, .rollCounterClockwise: .pi / 2
        case .down, .right, .rollClockwise: -.pi / 2
        }
    }

    func axis(of rig: CameraRig) -> SIMD3<Float> {
        switch self {
        case .left, .right: rig.up
        case .up, .down: rig.right
        case .rollClockwise, .rollCounterClockwise: rig.forward
        }
    }
}

struct ViewAxes: Equatable {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
}

/// Owns the RealityKit scene for the part: the document's bodies fold where the phone's crease is
/// on screen, in whatever orientation they are viewed. Folds can be held and stacked
/// (see FoldSession). All app chrome (angle readout, buttons) lives in EditorView as a floating HUD.
@MainActor
final class ViewportEntities: ObservableObject {
    private let sceneAnchor = AnchorEntity(world: .zero)
    private var partEntities: [UUID: ModelEntity] = [:]
    private let previewEntity = ModelEntity()
    private let featureHighlight = ModelEntity()
    private let cameraEntity = PerspectiveCamera()
    private let keyLight = DirectionalLight()
    private let referenceGeometry = ReferenceScene()
    @Published var referenceVisibility = ReferenceVisibility() {
        didSet { referenceGeometry.apply(referenceVisibility) }
    }

    private var rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
    private var viewportSize = CGSize(width: 951, height: 669)
    private var crease = ScreenCrease.centeredVertical

    private weak var appModel: AppModel?
    private var hingeSubscription: AnyCancellable?
    private var selectionSubscription: AnyCancellable?
    private var isSetUp = false

    /// Called after anything that changes the saved design (every undoable edit, and undo itself).
    var onContentChange: (() -> Void)?
    private var startingView: (camera: CameraRig, corner: CornerStyle)?

    init(startingView: (camera: CameraRig, corner: CornerStyle)? = nil) {
        self.startingView = startingView
    }

    /// Folds that have been held, and whether the shape is currently frozen.
    private var session: FoldSession?
    /// The camera, for the view cube and the sketch overlay to follow.
    @Published private(set) var camera = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
    var viewAxes: ViewAxes { ViewAxes(right: camera.right, up: camera.up, forward: camera.forward) }
    private var snapTask: Task<Void, Never>?
    /// Smooth (default) or sharp corner at the fold; double-tap the figure to switch.
    @Published private(set) var cornerStyle: CornerStyle = .fillet
    private var zoomTask: Task<Void, Never>?
    private var zoomGoal: Float?

    /// Sketching: drawing shapes on a plane and extruding them into parts.
    let sketch = SketchController()
    private var sketchObserver: AnyCancellable?

    /// The part the user last tapped, highlighted, and the pop-up menu from pressing and holding.
    @Published private(set) var selectedPartID: UUID?
    @Published private(set) var menu: PartMenu?
    @Published private(set) var hasClipboard = false
    private var clipboard: RenderMesh?
    private var sceneRevision = 0
    /// The parts as last drawn, for picking.
    private var shownParts: [(id: UUID, mesh: RenderMesh)] = []
    /// Where the shown parts balance, folds included. The view turns about this point, not the crease.
    private var centerOfMass: SIMD3<Float>?
    private var lastDocumentMeshes: [UUID: RenderMesh] = [:]
    private var sessionIDByDocumentID: [UUID: UUID] = [:]
    @Published private(set) var isHolding = false
    @Published private(set) var isBendingSelection = false
    private var activeFillet: (documentID: UUID, sessionID: UUID, selection: MeshFeatureSelection, base: RenderMesh)?
    private var filletHolding = false
    @Published private(set) var foldCount = 0
    /// Bounding boxes of the parts as drawn, for dimension labels.
    @Published private(set) var partBounds: [PartBounds] = []

    /// Everything that determines the displayed mesh, so a rebuild only happens when it changed.
    private struct BuildKey {
        var bend: Double
        var frame: FoldFrame
        var revision: Int
        var holding: Bool
        var scene: Int
        var corner: CornerStyle
    }
    private var lastBuild: BuildKey?

    /// Everything one undo step brings back: the document, the folds, the corner style and the
    /// bookkeeping that ties document bodies to workbench parts.
    private struct UndoSnapshot {
        var document: AppModel.DocumentSnapshot
        var session: FoldSession?
        var corner: CornerStyle
        var lastDocumentMeshes: [UUID: RenderMesh]
        var sessionIDByDocumentID: [UUID: UUID]
    }
    private var undoStack: [UndoSnapshot] = []
    @Published private(set) var touchUpStatus: TouchUpStatus = .idle
    private var touchUpDismiss: Task<Void, Never>?
    var touchUpEngine = TouchUpEngine()
    private var redoStack: [UndoSnapshot] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private static let undoLimit = 100
    private var lastBuildTime: CFAbsoluteTime = 0
    private var pendingRefresh: DispatchWorkItem?

    /// Plain matte blue. No metalness and full roughness so the environment doesn't reflect in it —
    /// the earlier mirror-smooth default read as a glassy black brick.
    private let blockMaterial = SimpleMaterial(
        color: UIColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        roughness: 1.0,
        isMetallic: false
    )

    /// The selected part, so it reads clearly which one a long press will act on.
    private var styleMaterials: [String: SimpleMaterial] = [:]

    private let selectedMaterial = SimpleMaterial(
        color: UIColor(red: 0.42, green: 0.72, blue: 1.0, alpha: 1),
        roughness: 1.0,
        isMetallic: false
    )
    private let previewMaterial = SimpleMaterial(
        color: UIColor(red: 0.3, green: 0.85, blue: 0.7, alpha: 0.75),
        roughness: 1.0,
        isMetallic: false
    )

    private let cutPreviewMaterial = SimpleMaterial(
        color: UIColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 0.8),
        roughness: 1.0,
        isMetallic: false
    )

    private static let bendThreshold = 0.05 * .pi / 180
    /// At most ~20 mesh rebuilds a second while dragging; the last state is always applied.
    private static let minRebuildInterval: CFAbsoluteTime = 0.05

    func setUp(in content: inout RealityViewCameraContent, appModel: AppModel) {
        guard !isSetUp else { return }
        isSetUp = true
        self.appModel = appModel

        sceneAnchor.addChild(previewEntity)
        sceneAnchor.addChild(featureHighlight)
        sceneAnchor.addChild(referenceGeometry.root)
        referenceGeometry.apply(referenceVisibility)
        content.add(sceneAnchor)
        sketchObserver = sketch.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.updatePreview()
            }
        }

        keyLight.light = DirectionalLightComponent(color: .white, intensity: 3000, isRealWorldProxy: false)
        keyLight.look(at: .zero, from: SIMD3<Float>(0.2, 0.3, 0.25), relativeTo: nil)
        content.add(keyLight)

        // `.virtual` alone doesn't place or frame a camera; supply one whose field of view matches
        // the math in CameraRig, framed from the actual launch geometry.
        cameraEntity.components.set(PerspectiveCameraComponent(
            near: 0.005, far: 20, fieldOfViewInDegrees: 60, fieldOfViewOrientation: .vertical
        ))
        content.add(cameraEntity)
        content.camera = .virtual
        // Deliberately no `content.cameraTarget` or `.realityViewCameraControls`: both take over
        // the camera transform, which CameraRig owns.
        frameCamera(around: initialFramingBounds(appModel: appModel))
        if let start = startingView {
            rig = start.camera
            cornerStyle = start.corner
        }
        applyDebugOverrides()
        applyCamera()

        // Follow the hinge directly rather than waiting for SwiftUI to happen to re-run `update`.
        // `@Published` emits *before* it stores the new value, so use the emitted value.
        hingeSubscription = appModel.hingeInput.$bendAngleRadians.sink { [weak self] bend in
            self?.selectionBendChanged(bend)
            self?.refreshFold(bend: bend)
        }
        selectionSubscription = appModel.selection.$selection.sink { [weak self, weak appModel] selection in
            Task { @MainActor [weak self, weak appModel] in
                guard let self, let appModel else { return }
                self.applySelection(selection, appModel: appModel)
            }
        }
    }

    // MARK: Camera

    private func initialFramingBounds(appModel: AppModel) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(-0.03, -0.01, -0.03)
        var hi = SIMD3<Float>(0.03, 0.01, 0.03)
        for bodyID in appModel.document.partStudio.orderedBodyIDs {
            guard let solid = appModel.document.partStudio.body(bodyID) else { continue }
            let box = solid.mesh.boundingBox
            lo = simd_min(lo, box.min)
            hi = simd_max(hi, box.max)
        }
        return (lo, hi)
    }

    private func frameCamera(around bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        let center = (bounds.min + bounds.max) / 2
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.02)
        // A 3/4 diagonal viewing angle so width, thickness, and length are all legible at once.
        let direction = simd_normalize(SIMD3<Float>(1.1, 0.85, 1.4))
        rig.target = center
        rig.yaw = atan2(direction.x, direction.z)
        rig.pitch = asin(direction.y)
        rig.distance = (radius / tan(rig.fovYRadians / 2)) * 1.35
    }

    private func applyCamera() {
        cameraEntity.look(at: rig.target, from: rig.position, upVector: rig.up, relativeTo: nil)
        let snapshot = rig
        DispatchQueue.main.async { [weak self] in self?.camera = snapshot }
    }

    private func applyDebugOverrides() {
        #if DEBUG
        if let x = HingeInputManager.debugDouble("FoldFormDebugTargetX") { rig.target.x = Float(x) }
        if let yaw = HingeInputManager.debugDouble("FoldFormDebugYawDegrees") { rig.yaw = Float(yaw * .pi / 180) }
        if let pitch = HingeInputManager.debugDouble("FoldFormDebugPitchDegrees") { rig.pitch = Float(pitch * .pi / 180) }
        #endif
    }

    // MARK: Gestures (points of drag / pinch scale)

    /// Turns the camera to look straight at a face of the block, in a short eased animation.
    func snap(to face: ViewFace) {
        snapTask?.cancel()
        let target = rig.snapAngles(to: face)
        let start = (yaw: rig.yaw, pitch: rig.pitch, roll: rig.roll)
        let duration = 0.3
        snapTask = Task { @MainActor [weak self] in
            let began = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                guard let self else { return }
                let t = min((CFAbsoluteTimeGetCurrent() - began) / duration, 1)
                let eased = Float(t * t * (3 - 2 * t))
                self.rig.setAngles(
                    yaw: start.yaw + (target.yaw - start.yaw) * eased,
                    pitch: start.pitch + (target.pitch - start.pitch) * eased,
                    roll: start.roll + (target.roll - start.roll) * eased,
                    about: self.centerOfMass
                )
                self.cameraMoved()
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// The cube's arrows: a quarter turn of the view about the model, or a quarter roll in place.
    func step(_ step: ViewStep) {
        snapTask?.cancel()
        let pivot: SIMD3<Float>? = step.isRoll ? nil : centerOfMass
        let axis = step.axis(of: rig)
        let total = step.angle
        snapTask = Task { @MainActor [weak self] in
            let began = CFAbsoluteTimeGetCurrent()
            var applied: Float = 0
            while !Task.isCancelled {
                guard let self else { return }
                let t = min((CFAbsoluteTimeGetCurrent() - began) / 0.3, 1)
                let eased = Float(t * t * (3 - 2 * t))
                self.rig.orbit(about: axis, by: total * eased - applied, pivot: pivot)
                applied = total * eased
                self.cameraMoved()
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func rotate(by delta: CGSize) {
        snapTask?.cancel()
        menu = nil
        rig.rotate(dx: Float(delta.width), dy: Float(delta.height), about: centerOfMass)
        cameraMoved()
    }

    func pan(by delta: CGSize) {
        snapTask?.cancel()
        rig.pan(dx: Float(delta.width), dy: Float(delta.height), viewportHeight: Float(viewportSize.height))
        cameraMoved()
    }

    /// Zoom input moves a goal; the camera then glides to it a little every frame, so pinches and
    /// wheel ticks (which arrive in coarse steps) look continuous.
    func zoom(by scale: CGFloat) {
        snapTask?.cancel()
        guard scale.isFinite, scale > 0 else { return }
        let range = CameraRig.distanceRange
        zoomGoal = min(max((zoomGoal ?? rig.distance) / Float(scale), range.lowerBound), range.upperBound)
        guard zoomTask == nil else { return }
        zoomTask = Task { @MainActor [weak self] in
            var last = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let self, let goal = self.zoomGoal else { break }
                let now = CFAbsoluteTimeGetCurrent()
                // Frame-rate independent easing: closes ~60% of the gap every 0.08 s.
                let blend = Float(1 - exp(-(now - last) / 0.08))
                last = now
                self.rig.distance += (goal - self.rig.distance) * blend
                if abs(goal - self.rig.distance) < goal * 0.002 {
                    self.rig.distance = goal
                    self.zoomGoal = nil
                }
                self.cameraMoved()
            }
            self?.zoomTask = nil
        }
    }

    private func stopZoom() {
        zoomTask?.cancel()
        zoomTask = nil
        zoomGoal = nil
    }

    private func cameraMoved() {
        applyCamera()
        refreshFold()
    }

    func updateLayout(size: CGSize, crease: ScreenCrease) {
        guard size.width > 0, size.height > 0 else { return }
        viewportSize = size
        self.crease = crease
        refreshFold()
    }

    // MARK: Parts: selecting, copying, resetting

    /// The nearest part under a point of the viewport.
    func part(at point: CGPoint) -> UUID? {
        let ray = rig.ray(at: point, in: viewportSize)
        var best: (id: UUID, distance: Float)?
        for part in shownParts {
            guard let t = part.mesh.raycast(origin: ray.origin, direction: ray.direction) else { continue }
            if t < (best?.distance ?? .greatestFiniteMagnitude) { best = (part.id, t) }
        }
        return best?.id
    }

    private func select(_ id: UUID?) {
        guard selectedPartID != id else { return }
        selectedPartID = id
        if let id,
           let documentID = sessionIDByDocumentID.first(where: { $0.value == id })?.key {
            appModel?.selection.select(.body(documentID))
        } else if id == nil {
            appModel?.selection.clear()
        }
        sceneRevision += 1
        refreshFold()
    }

    private func applySelection(_ selection: SelectableKind?, appModel: AppModel) {
        let documentID: UUID?
        switch selection {
        case .body(let id): documentID = id
        case .feature(let id): documentID = appModel.document.partStudio.featureTree.feature(id: id)?.resultBodyID
        default: documentID = nil
        }
        let next = documentID.flatMap { sessionIDByDocumentID[$0] }
        guard selectedPartID != next else { return }
        selectedPartID = next
        sceneRevision += 1
        refreshFold()
    }

    func handleTap(at point: CGPoint) {
        guard !sketch.isActive else { return }
        menu = nil
        if activeFillet != nil {
            endFillet()
            return
        }
        if beginFillet(at: point) { return }
        select(part(at: point))
    }

    /// Selects a visible mesh corner or line. The document body ID remains stable even
    /// though the FoldSession uses a special identity for the first body.
    @discardableResult
    func beginFillet(documentBodyID: UUID, selection: MeshFeatureSelection) -> Bool {
        guard !sketch.isActive, !filletHolding, activeFillet == nil,
              let sessionID = sessionIDByDocumentID[documentBodyID],
              let base = session?.base[sessionID],
              MeshFillet.make(mesh: base, selection: selection, bend: .pi / 2) != nil else { return false }
        activeFillet = (documentBodyID, sessionID, selection, base)
        isBendingSelection = (appModel?.hingeInput.bendAngleRadians ?? 0) > FoldSession.flatThresholdRadians
        updateFeatureHighlight(selection)
        sceneRevision += 1
        refreshFold()
        return true
    }

    @discardableResult
    func beginFillet(at point: CGPoint) -> Bool {
        menu = nil
        // A screen-space edge tolerance is useful only if a tap just outside a silhouette can
        // reach the picker. Prefer the body under the ray, then try nearby visible edges of the
        // other bodies when the ray misses the solid itself.
        let rayHitID = part(at: point)
        let orderedParts = shownParts.sorted { $0.id == rayHitID && $1.id != rayHitID }
        for part in orderedParts {
            guard let selected = MeshFeaturePicker.pick(mesh: part.mesh, rig: rig, size: viewportSize, point: point),
                  let documentID = sessionIDByDocumentID.first(where: { $0.value == part.id })?.key else { continue }
            if beginFillet(documentBodyID: documentID, selection: selected) { return true }
        }
        endFillet(commit: false)
        return false
    }

    /// Deselecting commits the preview once; explicit cancellation restores the document unchanged.
    func endFillet(bend: Double? = nil, commit: Bool = true) {
        guard let active = activeFillet else { return }
        activeFillet = nil
        isBendingSelection = false
        featureHighlight.model = nil
        let angle = bend ?? appModel?.hingeInput.bendAngleRadians ?? 0
        if commit, commitFillet(active, bend: angle) {
            // The just-edited body remains still while the hinge opens, as it does after Hold.
            filletHolding = true
            isHolding = true
        }
        sceneRevision += 1
        refreshFold()
    }

    @discardableResult
    func holdSelectionFillet(bend: Double) -> Bool {
        guard let active = activeFillet, bend > FoldSession.flatThresholdRadians,
              commitFillet(active, bend: bend) else { return false }
        activeFillet = nil
        isBendingSelection = false
        featureHighlight.model = nil
        filletHolding = true
        isHolding = true
        sceneRevision += 1
        refreshFold(bend: bend)
        return true
    }

    func selectionBendChanged(_ bend: Double) {
        let bending = activeFillet != nil && bend > FoldSession.flatThresholdRadians
        if isBendingSelection != bending { isBendingSelection = bending }
        guard filletHolding, bend <= FoldSession.flatThresholdRadians else { return }
        filletHolding = false
        isHolding = session?.isHolding ?? false
        sceneRevision += 1
    }

    private func commitFillet(_ active: (documentID: UUID, sessionID: UUID, selection: MeshFeatureSelection, base: RenderMesh), bend: Double) -> Bool {
        guard let appModel, let mesh = MeshFillet.make(mesh: active.base, selection: active.selection, bend: bend) else { return false }
        return transact {
            appModel.applyBodyEdit([active.documentID: mesh], label: "Fillet")
            return .commit
        } == .commit
    }

    private func updateFeatureHighlight(_ selection: MeshFeatureSelection) {
        let yellow = UnlitMaterial(color: UIColor.systemYellow)
        switch selection {
        case .vertex(let point):
            featureHighlight.model = ModelComponent(mesh: .generateSphere(radius: 0.0018), materials: [yellow])
            featureHighlight.position = point
            featureHighlight.orientation = simd_quatf()
        case .edge(let a, let b):
            let direction = b - a
            let length = simd_length(direction)
            featureHighlight.model = ModelComponent(mesh: .generateBox(size: SIMD3<Float>(0.0015, length, 0.0015)), materials: [yellow])
            featureHighlight.position = (a + b) / 2
            featureHighlight.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction / length)
        }
    }

    /// Double-tapping the figure switches the fold between a smooth and a sharp corner.
    func handleDoubleTap(at point: CGPoint) {
        guard !sketch.isActive, part(at: point) != nil else { return }
        menu = nil
        push(makeUndoSnapshot())
        cornerStyle = cornerStyle.toggled
        refreshFold()
    }

    func handleLongPress(at point: CGPoint) {
        guard !sketch.isActive else { return }
        if activeFillet != nil {
            endFillet()
            return
        }
        if let id = part(at: point) {
            select(id)
            menu = PartMenu(partID: id, point: point)
        } else if hasClipboard {
            menu = PartMenu(partID: nil, point: point)
        }
    }

    func dismissMenu() { menu = nil }

    /// Everything on the workbench exactly as it is shown right now, folds included.
    func exportMesh() -> RenderMesh? {
        let merged = RenderMesh.merged(shownParts.map(\.mesh))
        return merged.positions.isEmpty ? nil : merged
    }

    func duplicate(_ id: UUID) {
        guard let mesh = session?.base[id] else { return }
        let box = mesh.boundingBox
        let corners = [box.min, box.max]
        let extent = corners.map { simd_dot($0, rig.right) }
        let width = abs(extent[1] - extent[0])
        let copy = mesh.translated(by: rig.right * (width + 0.006))
        let before = makeUndoSnapshot()
        guard let appModel, !appModel.addViewportSolids([copy]).isEmpty else { return }
        push(before)
        menu = nil
        selectedPartID = nil
        sceneRevision += 1
        refreshFold()
    }

    func copy(_ id: UUID) {
        guard let mesh = session?.base[id] else { return }
        clipboard = mesh
        hasClipboard = true
        menu = nil
    }

    func paste(at point: CGPoint) {
        guard let mesh = clipboard else { return }
        let ray = rig.ray(at: point, in: viewportSize)
        let denominator = simd_dot(ray.direction, rig.forward)
        guard denominator > 1e-4 else { return }
        let t = simd_dot(rig.target - ray.origin, rig.forward) / denominator
        let hit = ray.origin + ray.direction * t
        let pasted = mesh.translated(by: hit - mesh.center)
        let before = makeUndoSnapshot()
        guard let appModel, !appModel.addViewportSolids([pasted]).isEmpty else { return }
        push(before)
        menu = nil
        selectedPartID = nil
        sceneRevision += 1
        refreshFold()
    }

    func delete(_ id: UUID) {
        let before = makeUndoSnapshot()
        guard let documentID = sessionIDByDocumentID.first(where: { $0.value == id })?.key,
              appModel?.removeViewportSolid(bodyID: documentID) == true else { return }
        push(before)
        menu = nil
        selectedPartID = nil
        sceneRevision += 1
        refreshFold()
    }

    /// Back to the very first flat plate: no extra parts, no folds, no sketch, the opening view.
    func resetEverything() {
        push(makeUndoSnapshot())
        activeFillet = nil
        filletHolding = false
        isBendingSelection = false
        isHolding = false
        featureHighlight.model = nil
        snapTask?.cancel()
        stopZoom()
        cornerStyle = .fillet
        sketch.end()
        menu = nil
        selectedPartID = nil
        if let appModel {
            appModel.resetDocumentToInitialPlate()
            let meshes = documentMeshes(from: appModel)
            if !meshes.isEmpty {
                session = makeSession(from: meshes)
                lastDocumentMeshes = Dictionary(uniqueKeysWithValues: meshes.map { ($0.id, $0.mesh) })
            }
        }
        sceneRevision += 1
        if let appModel {
            frameCamera(around: initialFramingBounds(appModel: appModel))
            applyCamera()
        }
        lastBuild = nil
        publishSession()
        refreshFold()
    }

    // MARK: Sketching

    /// Starts drawing on the surface of whatever side the camera is nearest to facing.
    func beginSketch() {
        let face = rig.nearestFace
        var facing = rig
        let angles = rig.snapAngles(to: face)
        facing.yaw = angles.yaw
        facing.pitch = angles.pitch
        facing.roll = angles.roll
        func exact(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x.rounded(), v.y.rounded(), v.z.rounded()) }
        let u = exact(facing.right), v = exact(facing.up)
        let n = simd_cross(u, v)

        // Sit on the front-most surface of everything on the workbench, so new shapes attach to it.
        let everything = session?.base.values.flatMap(\.positions) ?? []
        let frontMost = everything.map { simd_dot($0, n) }.max() ?? simd_dot(rig.target, n)
        let origin = rig.target + n * (frontMost - simd_dot(rig.target, n))
        menu = nil
        select(nil)
        sketch.begin(on: SketchPlane(origin: origin, u: u, v: v, n: n))
        snap(to: face)
    }

    func endSketch() {
        sketch.end()
    }

    /// Finishes the extrusion: each closed shape becomes its own part, ready to bend.
    /// `recordUndo` is false when the caller is already inside a `transact`.
    func confirmExtrude(recordUndo: Bool = true) {
        let cutting = sketch.isCutting
        let solids = sketch.confirmExtrude()
        guard !solids.isEmpty else { return }
        if recordUndo { push(makeUndoSnapshot()) }
        if cutting { appModel?.addViewportCuts(solids) } else { appModel?.addViewportSolids(solids) }
        sceneRevision += 1
        endSketch()
        refreshFold()
    }

    private var planeWorldPerPoint: Float {
        guard let plane = sketch.plane else { return 0.0005 }
        let distance = max(simd_dot(plane.origin - rig.position, rig.forward), 0.01)
        return 2 * distance * tan(rig.fovYRadians / 2) / Float(max(viewportSize.height, 1))
    }

    // MARK: Touch up

    /// Smooths odd bumps and snaps to what was probably meant. While sketching it works on the
    /// outlines being drawn; otherwise on the bodies. Either way it can be undone.
    func touchUp() {
        guard touchUpStatus != .working, let appModel else { return }
        touchUpDismiss?.cancel()
        touchUpStatus = .working
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: TouchUpOutcome
            if self.sketch.isActive, !self.sketch.isExtruding {
                let result = await self.touchUpEngine.touchUp(
                    shapes: self.sketch.shapes,
                    segments: self.sketch.lineSegments,
                    tolerance: self.sketch.currentSnapTolerance
                )
                if let shapes = result.shapes { self.sketch.replaceShapes(shapes) }
                outcome = result.outcome
            } else {
                let result = await self.touchUpEngine.touchUp(bodies: self.documentMeshes(from: appModel), styles: appModel.partStyles)
                if result.outcome.changed {
                    self.push(self.makeUndoSnapshot())
                    appModel.applyTouchUp(result.meshes)
                    appModel.applyFinish(styles: result.styles, additions: result.additions)
                    self.sceneRevision += 1
                    self.refreshFold()
                }
                outcome = result.outcome
            }
            self.touchUpStatus = .message(outcome.message)
            self.touchUpDismiss = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                guard !Task.isCancelled else { return }
                self?.touchUpStatus = .idle
            }
        }
    }

    // MARK: Undo

    /// True when undo would do something: a stored step, or a shape being drawn.
    var hasUndo: Bool { canUndo || (sketch.isActive && (sketch.isExtruding || !sketch.shapes.isEmpty)) }

    private func makeUndoSnapshot() -> UndoSnapshot? {
        guard let appModel else { return nil }
        return UndoSnapshot(
            document: appModel.snapshotDocument(),
            session: session,
            corner: cornerStyle,
            lastDocumentMeshes: lastDocumentMeshes,
            sessionIDByDocumentID: sessionIDByDocumentID
        )
    }

    /// Records `snapshot` as an undo step. Any new edit ends the redo history.
    private func push(_ snapshot: UndoSnapshot?) {
        guard let snapshot else { return }
        appendUndo(snapshot)
        redoStack.removeAll()
        canRedo = false
        notifyContentChange()
    }

    private func appendUndo(_ snapshot: UndoSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        canUndo = true
    }

    enum TransactionOutcome {
        /// Keep the changes as one undo step.
        case commit
        /// Keep the changes without an undo step (sketch progress has its own undo).
        case keep
        /// Put everything back.
        case rollback
    }

    /// Runs `body` as one undoable step. When it returns false everything it changed is put back and
    /// no step is recorded, so a plan that fails half way leaves the design as it was.
    @discardableResult
    func transact(_ body: () -> Bool) -> Bool {
        transact { body() ? .commit : .rollback } != .rollback
    }

    @discardableResult
    func transact(_ body: () -> TransactionOutcome) -> TransactionOutcome {
        guard let before = makeUndoSnapshot() else { return body() }
        let sketchWasActive = sketch.isActive
        let shapesBefore = sketch.shapes
        let outcome = body()
        switch outcome {
        case .commit: push(before)
        case .keep: break
        case .rollback:
            restore(before, endingSketch: false)
            if !sketchWasActive {
                sketch.end()
            } else if sketch.shapes != shapesBefore {
                sketch.replaceShapes(shapesBefore)
            }
        }
        return outcome
    }

    /// Takes back the last thing that changed the model: an extrude or cut, a duplicate, paste or
    /// delete, a hold or fold reset, a corner switch, or a reset of everything. While sketching it
    /// first takes back the shape being drawn.
    func undo() {
        if sketch.isActive {
            if sketch.isExtruding { sketch.cancelExtrude(); return }
            if !sketch.shapes.isEmpty { sketch.undoShape(); return }
        }
        guard appModel != nil, let snapshot = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty
        if let current = makeUndoSnapshot() {
            redoStack.append(current)
            if redoStack.count > Self.undoLimit { redoStack.removeFirst() }
            canRedo = true
        }
        restore(snapshot, endingSketch: true)
        notifyContentChange()
    }

    /// Puts back what the last undo took away.
    func redo() {
        guard appModel != nil, let snapshot = redoStack.popLast() else { return }
        canRedo = !redoStack.isEmpty
        if let current = makeUndoSnapshot() { appendUndo(current) }
        restore(snapshot, endingSketch: true)
        notifyContentChange()
    }

    private func restore(_ snapshot: UndoSnapshot, endingSketch: Bool) {
        guard let appModel else { return }
        activeFillet = nil
        filletHolding = false
        isBendingSelection = false
        isHolding = snapshot.session?.isHolding ?? false
        featureHighlight.model = nil
        // A rolled-back command keeps the user's selection; an undo drops it.
        let keptSelection = endingSketch ? nil : selectedDocumentBodyID
        snapTask?.cancel()
        menu = nil
        if endingSketch {
            sketch.end()
            selectedPartID = nil
        }
        appModel.restoreDocument(snapshot.document)
        session = snapshot.session
        cornerStyle = snapshot.corner
        lastDocumentMeshes = snapshot.lastDocumentMeshes
        sessionIDByDocumentID = snapshot.sessionIDByDocumentID
        if let kept = keptSelection, let sessionID = sessionIDByDocumentID[kept] {
            selectedPartID = sessionID
            appModel.selection.select(.body(kept))
        } else if !endingSketch {
            selectedPartID = nil
        }
        sceneRevision += 1
        lastBuild = nil
        publishSession()
        refreshFold()
    }

    // MARK: Selection by document body (voice and Imagine)

    /// The document body the selected part comes from, if one is selected.
    var selectedDocumentBodyID: UUID? {
        selectedPartID.flatMap { id in sessionIDByDocumentID.first(where: { $0.value == id })?.key }
    }

    /// Selects a part by its document body, the way a tap would.
    func select(documentBodyID: UUID?) {
        refreshFold()
        select(documentBodyID.flatMap { sessionIDByDocumentID[$0] })
    }

    var bodyCount: Int { appModel?.document.partStudio.orderedBodyIDs.count ?? 0 }

    private func notifyContentChange() {
        // Deferred so the edit that caused it has finished before anything captures the scene.
        DispatchQueue.main.async { [weak self] in self?.onContentChange?() }
    }

    /// The workbench as it should be saved: every part's shape with held folds baked in, its colour,
    /// the corner style and the camera. Nil before the scene has been built.
    func captureDesign() -> DesignCapture? {
        guard let appModel, let session else { return nil }
        let documentIDBySessionID = Dictionary(uniqueKeysWithValues: sessionIDByDocumentID.map { ($0.value, $0.key) })
        let bodies = session.order.compactMap { id -> DesignBody? in
            guard let mesh = session.base[id], !mesh.positions.isEmpty else { return nil }
            return DesignBody(mesh: mesh, style: documentIDBySessionID[id].flatMap { appModel.partStyles[$0] })
        }
        return DesignCapture(bodies: bodies, corner: cornerStyle, camera: rig)
    }

    private func planePoint(_ point: CGPoint) -> SIMD2<Float>? {
        guard let plane = sketch.plane else { return nil }
        let ray = rig.ray(at: point, in: viewportSize)
        return plane.point(origin: ray.origin, direction: ray.direction)
    }

    func drawBegan(at point: CGPoint) {
        guard !sketch.isExtruding, let p = planePoint(point) else { return }
        sketch.dragBegan(at: p, snapTolerance: SketchController.snapPoints * planeWorldPerPoint)
    }

    func drawChanged(to point: CGPoint) {
        guard let p = planePoint(point) else { return }
        sketch.dragChanged(to: p, snapTolerance: SketchController.snapPoints * planeWorldPerPoint)
    }

    func drawEnded() {
        sketch.dragEnded()
    }

    func drawCancelled() {
        sketch.cancelDrag()
    }

    private func updatePreview() {
        let solids = sketch.isExtruding ? sketch.extrusions : []
        guard !solids.isEmpty,
              let mesh = try? MeshResource.generate(from: [Self.descriptor(for: RenderMesh.merged(solids))]) else {
            previewEntity.model = nil
            return
        }
        previewEntity.model = ModelComponent(mesh: mesh, materials: [sketch.isCutting ? cutPreviewMaterial : previewMaterial])
    }

    // MARK: Folding

    private func documentMeshes(from appModel: AppModel) -> [(id: UUID, mesh: RenderMesh)] {
        appModel.document.partStudio.orderedBodyIDs.compactMap { id in
            guard let solid = appModel.document.partStudio.body(id) else { return nil }
            return (id, solid.mesh)
        }
    }

    private func makeSession(from meshes: [(id: UUID, mesh: RenderMesh)]) -> FoldSession {
        guard let first = meshes.first else { return FoldSession(source: .empty) }
        sessionIDByDocumentID = [first.id: FoldSession.primaryID]
        var result = FoldSession(source: first.mesh)
        for part in meshes.dropFirst() {
            result.addPart(id: part.id, mesh: part.mesh)
            sessionIDByDocumentID[part.id] = part.id
        }
        return result
    }

    /// The Part Studio changed. Bodies that were only added or removed join or leave the workbench
    /// without disturbing folds already made; a body whose shape changed (or a different first
    /// plate) starts the folds over.
    private func syncSession(with parts: [(id: UUID, mesh: RenderMesh)], byID: [UUID: RenderMesh]) {
        let firstIsSame = parts.first.map { sessionIDByDocumentID[$0.id] == FoldSession.primaryID } ?? false
        let existingChanged = byID.contains { id, mesh in lastDocumentMeshes[id].map { $0 != mesh } ?? false }
        guard firstIsSame, !existingChanged else {
            session = makeSession(from: parts)
            lastDocumentMeshes = byID
            lastBuild = nil
            publishSession()
            return
        }
        for id in lastDocumentMeshes.keys where byID[id] == nil {
            if let sessionID = sessionIDByDocumentID[id] { session?.removePart(sessionID) }
            sessionIDByDocumentID[id] = nil
        }
        for part in parts where lastDocumentMeshes[part.id] == nil {
            session?.addPart(id: part.id, mesh: part.mesh)
            sessionIDByDocumentID[part.id] = part.id
        }
        lastDocumentMeshes = byID
        publishSession()
    }

    /// Called on every SwiftUI update and every camera move.
    func update(appModel: AppModel) {
        self.appModel = appModel
        refreshFold()
    }

    /// The fold as it is right now: cut along the on-screen crease, hinged about its direction.
    private func currentFrame() -> FoldFrame {
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        return rig.foldFrame(crease: crease, aspect: aspect)
    }

    private func needsRebuild(_ key: BuildKey) -> Bool {
        guard let last = lastBuild else { return true }
        if key.revision != last.revision || key.holding != last.holding || key.scene != last.scene || key.corner != last.corner { return true }
        // A held shape ignores both the hinge and the camera.
        if key.holding && activeFillet == nil { return false }
        if abs(key.bend - last.bend) > Self.bendThreshold { return true }
        // Moving the crease across a flat block changes nothing visible, so only follow it once
        // there is an actual bend.
        return key.bend > 1e-4 && !key.frame.isClose(to: last.frame)
    }

    private func refreshFold(bend bendOverride: Double? = nil) {
        guard let appModel else { return }
        let documentParts = documentMeshes(from: appModel)
        guard !documentParts.isEmpty else { return }
        let documentMeshesByID = Dictionary(uniqueKeysWithValues: documentParts.map { ($0.id, $0.mesh) })

        if session == nil {
            session = makeSession(from: documentParts)
            lastDocumentMeshes = documentMeshesByID
            lastBuild = nil
            publishSession()
        } else if lastDocumentMeshes != documentMeshesByID {
            syncSession(with: documentParts, byID: documentMeshesByID)
        }
        let bend = bendOverride ?? appModel.hingeInput.bendAngleRadians
        // Back at flat releases a hold.
        if session?.bendChanged(bend) == true { publishSession() }

        let key = BuildKey(
            bend: bend,
            frame: currentFrame(),
            revision: session?.revision ?? 0,
            holding: session?.isHolding ?? false,
            scene: sceneRevision,
            corner: cornerStyle
        )
        guard needsRebuild(key) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let sinceLast = now - lastBuildTime
        if lastBuild != nil, sinceLast < Self.minRebuildInterval {
            scheduleRefresh(after: Self.minRebuildInterval - sinceLast)
            return
        }

        pendingRefresh?.cancel()
        pendingRefresh = nil
        if rebuild(key) {
            lastBuild = key
            lastBuildTime = now
        }
    }

    // MARK: Hold

    /// Bakes the fold currently shown and holds it until the hinge is back at flat.
    func holdFold() {
        if let appModel, activeFillet != nil {
            _ = holdSelectionFillet(bend: appModel.hingeInput.bendAngleRadians)
            return
        }
        guard !filletHolding else { return }
        guard var current = session, let appModel else { return }
        let before = makeUndoSnapshot()
        if current.hold(bend: appModel.hingeInput.bendAngleRadians, frame: currentFrame(), corner: cornerStyle) {
            push(before)
            session = current
            publishSession()
            refreshFold()
        }
    }

    /// Removes the most recent held fold and goes back to following the hinge.
    func undoFold() {
        guard session?.foldCount ?? 0 > 0 else { return }
        push(makeUndoSnapshot())
        session?.undo()
        publishSession()
        refreshFold()
    }

    func resetFolds() {
        guard session?.foldCount ?? 0 > 0 else { return }
        push(makeUndoSnapshot())
        session?.clearFolds()
        publishSession()
        refreshFold()
    }

    /// Deferred: this can run during a SwiftUI view update, where publishing isn't allowed.
    private func publishSession() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let holding = (self.session?.isHolding ?? false) || self.filletHolding
            let count = self.session?.foldCount ?? 0
            if self.isHolding != holding { self.isHolding = holding }
            if self.foldCount != count { self.foldCount = count }
        }
    }

    private func scheduleRefresh(after delay: CFAbsoluteTime) {
        guard pendingRefresh == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingRefresh = nil
                self?.refreshFold()
            }
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @discardableResult
    private func rebuild(_ key: BuildKey) -> Bool {
        guard let session else { return false }
        var parts = session.displayedParts(bend: activeFillet != nil || filletHolding ? 0 : key.bend, frame: key.frame, corner: key.corner)
        if let active = activeFillet,
           let preview = MeshFillet.make(mesh: active.base, selection: active.selection, bend: key.bend),
           let index = parts.firstIndex(where: { $0.id == active.sessionID }) {
            parts[index].mesh = preview
        }
        var built: [UUID: MeshResource] = [:]
        for part in parts {
            guard let mesh = try? MeshResource.generate(from: [Self.descriptor(for: part.mesh)]) else { return false }
            built[part.id] = mesh
        }
        for id in Array(partEntities.keys) where built[id] == nil {
            partEntities[id]?.removeFromParent()
            partEntities[id] = nil
        }
        for part in parts {
            let entity = partEntities[part.id] ?? {
                let created = ModelEntity()
                sceneAnchor.addChild(created)
                partEntities[part.id] = created
                return created
            }()
            let highlighted = part.id == selectedPartID && parts.count > 1
            entity.model = ModelComponent(mesh: built[part.id]!, materials: [highlighted ? selectedMaterial : material(forPart: part.id)])
        }
        shownParts = parts
        let bounds = parts.compactMap { PartBounds($0.mesh) }
        Task { @MainActor [weak self] in
            if self?.partBounds != bounds { self?.partBounds = bounds }
        }
        centerOfMass = RenderMesh.centerOfMass(of: parts.map(\.mesh))
        return true
    }

    /// The colour chosen for a part, or the default blue.
    private func material(forPart id: UUID) -> SimpleMaterial {
        guard let documentID = sessionIDByDocumentID.first(where: { $0.value == id })?.key,
              let style = appModel?.partStyles[documentID] else { return blockMaterial }
        if let cached = styleMaterials[style.name] { return cached }
        let material = SimpleMaterial(
            color: UIColor(red: CGFloat(style.rgb.x), green: CGFloat(style.rgb.y), blue: CGFloat(style.rgb.z), alpha: 1),
            roughness: MaterialScalarParameter(floatLiteral: style.roughness),
            isMetallic: style.isMetallic
        )
        styleMaterials[style.name] = material
        return material
    }

    private static func descriptor(for mesh: RenderMesh) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "PartStudioBody")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        return descriptor
    }
}

/// Full-screen 3D canvas. No text, no docked panel — see EditorView for the floating HUD.
struct RealityViewport: View {
    @EnvironmentObject var appModel: AppModel
    /// Owned by EditorView so its HUD buttons (hold, undo) can act on the same scene.
    @ObservedObject var entities: ViewportEntities
    /// When on, a one-finger / mouse drag moves the object instead of rotating it.
    var oneFingerPans = false
    var darkMode = true
    var onViewportPress: () -> Void = {}

    private struct Layout: Equatable {
        var size: CGSize
        var crease: ScreenCrease
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RealityView { (content: inout RealityViewCameraContent) in
                    entities.setUp(in: &content, appModel: appModel)
                } update: { (_: inout RealityViewCameraContent) in
                    entities.update(appModel: appModel)
                }

                ViewportGestureView(
                    oneFingerPans: oneFingerPans,
                    drawMode: entities.sketch.isActive && !entities.sketch.isExtruding,
                    onRotate: { entities.rotate(by: $0) },
                    onPan: { entities.pan(by: $0) },
                    onZoom: { entities.zoom(by: $0) },
                    onTap: { point in
                        onViewportPress()
                        entities.handleTap(at: point)
                    },
                    onDoubleTap: { entities.handleDoubleTap(at: $0) },
                    onLongPress: { entities.handleLongPress(at: $0) },
                    onDrawBegan: { entities.drawBegan(at: $0) },
                    onDrawChanged: { entities.drawChanged(to: $0) },
                    onDrawEnded: { entities.drawEnded() },
                    onDrawCancelled: { entities.drawCancelled() }
                )
            }
            .task(id: layout(for: proxy)) {
                let l = layout(for: proxy)
                entities.updateLayout(size: l.size, crease: l.crease)
            }
        }
        .background(darkMode ? Color.black : Color.white)
        .ignoresSafeArea()
    }

    /// The physical crease is reported as a reserved `.division` region in window coordinates
    /// (e.g. a 40-pt-wide strip down the middle of the screen). Convert its center to a fraction
    /// of this viewport; fall back to a centered vertical crease if none is reported.
    private func layout(for proxy: GeometryProxy) -> Layout {
        let size = proxy.size
        let frame = proxy.frame(in: .global)
        guard let region = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first,
              size.width > 0, size.height > 0 else {
            return Layout(size: size, crease: .centeredVertical)
        }
        let r = region.frame
        let crease: ScreenCrease
        if r.width <= r.height {
            crease = ScreenCrease(axis: .vertical, fraction: Float((r.midX - frame.minX) / size.width))
        } else {
            crease = ScreenCrease(axis: .horizontal, fraction: Float((r.midY - frame.minY) / size.height))
        }
        guard (0.05...0.95).contains(crease.fraction) else {
            return Layout(size: size, crease: .centeredVertical)
        }
        return Layout(size: size, crease: crease)
    }
}
