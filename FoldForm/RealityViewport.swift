import SwiftUI
import RealityKit
import Combine
import UIKit

/// The pop-up shown by pressing and holding: on a part, or on empty space.
struct PartMenu: Equatable {
    var partID: UUID?
    var point: CGPoint
}

struct ViewAxes: Equatable {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
}

/// Owns the RealityKit scene for the part: document geometry folds around its stable local crease,
/// while the camera can orbit independently like a CAD viewport. Folds can be held and stacked
/// (see FoldSession). All app chrome (angle readout, buttons) lives in RootView as a floating HUD.
@MainActor
final class ViewportEntities: ObservableObject {
    private let sceneAnchor = AnchorEntity(world: .zero)
    private var partEntities: [UUID: ModelEntity] = [:]
    private let previewEntity = ModelEntity()
    private let creaseEntity = ModelEntity()
    private let obstacleEntity = ModelEntity()
    private let cameraEntity = PerspectiveCamera()
    private let keyLight = DirectionalLight()
    private var collisionProxies: [UUID: Entity] = [:]
    private var collisionSubscriptions: [EventSubscription] = []

    private var rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
    private var viewportSize = CGSize(width: 951, height: 669)

    private weak var appModel: AppModel?
    private var hingeSubscription: AnyCancellable?
    private var selectionSubscription: AnyCancellable?
    private var collisionStateSubscription: AnyCancellable?
    private var isSetUp = false

    /// Folds that have been held, and whether the shape is currently frozen.
    private var session: FoldSession?
    /// The camera, for the view cube and the sketch overlay to follow.
    @Published private(set) var camera = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
    var viewAxes: ViewAxes { ViewAxes(right: camera.right, up: camera.up, forward: camera.forward) }
    private var snapTask: Task<Void, Never>?

    /// Sketching: drawing shapes on a plane and extruding them into parts.
    let sketch = SketchController()
    private var sketchObserver: AnyCancellable?
    private var lastDrawPoint: CGPoint?

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
    private var orbitPivot: SIMD3<Float>?
    private var lastDocumentMeshes: [UUID: RenderMesh] = [:]
    private var sessionIDByDocumentID: [UUID: UUID] = [:]
    @Published private(set) var isHolding = false
    @Published private(set) var foldCount = 0

    /// Everything that determines the displayed mesh, so a rebuild only happens when it changed.
    private struct BuildKey {
        var bend: Double
        var frame: FoldFrame
        var revision: Int
        var holding: Bool
        var scene: Int
        var collisionActive: Bool
    }
    private var lastBuild: BuildKey?
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
    private let selectedMaterial = SimpleMaterial(
        color: UIColor(red: 0.42, green: 0.72, blue: 1.0, alpha: 1),
        roughness: 1.0,
        isMetallic: false
    )
    private let collisionMaterial = SimpleMaterial(
        color: UIColor(red: 0.95, green: 0.12, blue: 0.08, alpha: 1),
        roughness: 1.0,
        isMetallic: false
    )
    private let previewMaterial = SimpleMaterial(
        color: UIColor(red: 0.3, green: 0.85, blue: 0.7, alpha: 0.75),
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
        sceneAnchor.addChild(creaseEntity)
        sceneAnchor.addChild(obstacleEntity)
        content.add(sceneAnchor)

        creaseEntity.model = ModelComponent(
            mesh: .generateBox(size: SIMD3<Float>(0.002, 0.002, 1)),
            materials: [UnlitMaterial(color: .init(red: 1, green: 0.84, blue: 0, alpha: 1))]
        )
        obstacleEntity.model = ModelComponent(
            mesh: .generateBox(size: SIMD3<Float>(0.028, 0.012, 0.06)),
            materials: [SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.60), roughness: 1, isMetallic: false)]
        )
        obstacleEntity.position = SIMD3<Float>(0.034, 0.045, 0)
        let obstacleSize = SIMD3<Float>(0.028, 0.012, 0.06)
        obstacleEntity.components.set(CollisionComponent(shapes: [.generateBox(size: obstacleSize)]))
        obstacleEntity.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .static))
        collisionSubscriptions = [
            content.subscribe(to: CollisionEvents.Began.self, on: obstacleEntity) { [weak appModel] _ in
                Task { @MainActor [weak appModel] in appModel?.reportCollisionBegan() }
            },
            content.subscribe(to: CollisionEvents.Ended.self, on: obstacleEntity) { [weak appModel] _ in
                Task { @MainActor [weak appModel] in appModel?.reportCollisionEnded() }
            }
        ]
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
        applyDebugOverrides()
        applyCamera()

        // Follow the hinge directly rather than waiting for SwiftUI to happen to re-run `update`.
        // `@Published` emits *before* it stores the new value, so use the emitted value.
        hingeSubscription = appModel.hingeInput.$bendAngleRadians.sink { [weak self] bend in
            self?.refreshFold(bend: bend)
        }
        selectionSubscription = appModel.selection.$selection.sink { [weak self, weak appModel] selection in
            Task { @MainActor [weak self, weak appModel] in
                guard let self, let appModel else { return }
                self.applySelection(selection, appModel: appModel)
            }
        }
        collisionStateSubscription = appModel.collision.$state.sink { [weak self] _ in
            self?.refreshFold()
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
        let start = (yaw: rig.yaw, pitch: rig.pitch)
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
                    about: self.centerOfMass
                )
                self.cameraMoved()
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func rotate(by delta: CGSize) {
        snapTask?.cancel()
        menu = nil
        rig.rotate(dx: Float(delta.width), dy: Float(delta.height), about: orbitPivot ?? centerOfMass)
        cameraMoved()
    }

    /// Captures the surface under the finger before orbiting begins, matching CAD manipulators
    /// where the grabbed point stays visually anchored while the camera rotates.
    func beginRotate(at point: CGPoint) {
        let ray = rig.ray(at: point, in: viewportSize)
        orbitPivot = shownParts
            .compactMap { part -> (distance: Float, point: SIMD3<Float>)? in
                part.mesh.raycastHit(origin: ray.origin, direction: ray.direction)
            }
            .min(by: { $0.distance < $1.distance })?.point ?? centerOfMass
    }

    func endRotate() {
        orbitPivot = nil
    }

    func pan(by delta: CGSize) {
        snapTask?.cancel()
        rig.pan(dx: Float(delta.width), dy: Float(delta.height), viewportHeight: Float(viewportSize.height))
        cameraMoved()
    }

    func zoom(by scale: CGFloat) {
        snapTask?.cancel()
        rig.zoom(scale: Float(scale))
        cameraMoved()
    }

    private func cameraMoved() {
        applyCamera()
        refreshFold()
    }

    func updateLayout(size: CGSize, crease _: ScreenCrease) {
        guard size.width > 0, size.height > 0 else { return }
        viewportSize = size
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
        select(part(at: point))
    }

    func handleLongPress(at point: CGPoint) {
        guard !sketch.isActive else { return }
        if let id = part(at: point) {
            select(id)
            menu = PartMenu(partID: id, point: point)
        } else if hasClipboard {
            menu = PartMenu(partID: nil, point: point)
        }
    }

    func dismissMenu() { menu = nil }

    func duplicate(_ id: UUID) {
        guard let mesh = session?.base[id] else { return }
        let box = mesh.boundingBox
        let corners = [box.min, box.max]
        let extent = corners.map { simd_dot($0, rig.right) }
        let width = abs(extent[1] - extent[0])
        let copy = mesh.translated(by: rig.right * (width + 0.006))
        guard let appModel, !appModel.addViewportSolids([copy]).isEmpty else { return }
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
        guard let appModel, !appModel.addViewportSolids([pasted]).isEmpty else { return }
        selectedPartID = nil
        sceneRevision += 1
        refreshFold()
    }

    func delete(_ id: UUID) {
        guard let documentID = sessionIDByDocumentID.first(where: { $0.value == id })?.key,
              appModel?.removeViewportSolid(bodyID: documentID) == true else { return }
        menu = nil
        selectedPartID = nil
        sceneRevision += 1
        refreshFold()
    }

    /// Back to the very first flat plate: no extra parts, no folds, no sketch, the opening view.
    func resetEverything() {
        snapTask?.cancel()
        sketch.end()
        menu = nil
        selectedPartID = nil
        orbitPivot = nil
        if let appModel {
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
    func confirmExtrude() {
        let solids = sketch.confirmExtrude()
        guard !solids.isEmpty else { return }
        appModel?.addViewportSolids(solids)
        sceneRevision += 1
        refreshFold()
    }

    private var planeWorldPerPoint: Float {
        guard let plane = sketch.plane else { return 0.0005 }
        let distance = max(simd_dot(plane.origin - rig.position, rig.forward), 0.01)
        return 2 * distance * tan(rig.fovYRadians / 2) / Float(max(viewportSize.height, 1))
    }

    private func planePoint(_ point: CGPoint) -> SIMD2<Float>? {
        guard let plane = sketch.plane else { return nil }
        let ray = rig.ray(at: point, in: viewportSize)
        return plane.point(origin: ray.origin, direction: ray.direction)
    }

    func drawBegan(at point: CGPoint) {
        lastDrawPoint = point
        guard !sketch.isExtruding, let p = planePoint(point) else { return }
        sketch.dragBegan(at: p, snapTolerance: SketchController.snapPoints * planeWorldPerPoint)
    }

    func drawChanged(to point: CGPoint) {
        defer { lastDrawPoint = point }
        if sketch.isExtruding {
            if let last = lastDrawPoint {
                sketch.extrudeDrag(dy: point.y - last.y, worldPerPoint: planeWorldPerPoint)
            }
            return
        }
        guard let p = planePoint(point) else { return }
        sketch.dragChanged(to: p, snapTolerance: SketchController.snapPoints * planeWorldPerPoint)
    }

    func drawEnded() {
        lastDrawPoint = nil
        sketch.dragEnded()
    }

    func drawCancelled() {
        lastDrawPoint = nil
        sketch.cancelDrag()
    }

    private func updatePreview() {
        let solids = sketch.isExtruding ? sketch.extrusions : []
        guard !solids.isEmpty,
              let mesh = try? MeshResource.generate(from: [Self.descriptor(for: RenderMesh.merged(solids))]) else {
            previewEntity.model = nil
            return
        }
        previewEntity.model = ModelComponent(mesh: mesh, materials: [previewMaterial])
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

    /// Called on every SwiftUI update and every camera move.
    func update(appModel: AppModel) {
        self.appModel = appModel
        refreshFold()
    }

    /// The fold as it is right now: bend the document's local x = 0 crease around local z.
    /// Camera orbiting changes only presentation; it never changes the model's bend plane.
    private func currentFrame() -> FoldFrame {
        let mesh = session?.source ?? .empty
        let box = mesh.boundingBox
        return FoldFrame(
            pivot: SIMD3<Float>(0, (box.min.y + box.max.y) / 2, (box.min.z + box.max.z) / 2),
            axis: SIMD3<Float>(0, 0, 1),
            normal: SIMD3<Float>(1, 0, 0)
        )
    }

    private func needsRebuild(_ key: BuildKey) -> Bool {
        guard let last = lastBuild else { return true }
        if key.revision != last.revision || key.holding != last.holding || key.scene != last.scene || key.collisionActive != last.collisionActive { return true }
        // A held shape ignores both the hinge and the camera.
        if key.holding { return false }
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

        // A changed Part Studio starts a fresh presentation session, while keeping every body in
        // the same workbench instead of silently rendering only the last feature result.
        if session == nil || lastDocumentMeshes != documentMeshesByID {
            session = makeSession(from: documentParts)
            lastDocumentMeshes = documentMeshesByID
            lastBuild = nil
            publishSession()
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
            collisionActive: appModel.collisionIsActive
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
        guard var current = session, let appModel else { return }
        if current.hold(bend: appModel.hingeInput.bendAngleRadians, frame: currentFrame()) {
            session = current
            publishSession()
            refreshFold()
        }
    }

    /// Removes the most recent held fold and goes back to following the hinge.
    func undoFold() {
        guard session?.foldCount ?? 0 > 0 else { return }
        session?.undo()
        publishSession()
        refreshFold()
    }

    func resetFolds() {
        guard session?.foldCount ?? 0 > 0 else { return }
        session?.clearFolds()
        publishSession()
        refreshFold()
    }

    /// Deferred: this can run during a SwiftUI view update, where publishing isn't allowed.
    private func publishSession() {
        let holding = session?.isHolding ?? false
        let count = session?.foldCount ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
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
        let parts = session.displayedParts(bend: key.bend, frame: key.frame)
        var built: [UUID: MeshResource] = [:]
        for part in parts {
            guard let mesh = try? MeshResource.generate(from: [Self.descriptor(for: part.mesh)]) else { return false }
            built[part.id] = mesh
        }
        for id in Array(partEntities.keys) where built[id] == nil {
            partEntities[id]?.removeFromParent()
            partEntities[id] = nil
        }
        for id in Array(collisionProxies.keys) where built[id] == nil {
            collisionProxies[id]?.removeFromParent()
            collisionProxies[id] = nil
        }
        for part in parts {
            let entity = partEntities[part.id] ?? {
                let created = ModelEntity()
                sceneAnchor.addChild(created)
                partEntities[part.id] = created
                return created
            }()
            let highlighted = part.id == selectedPartID && parts.count > 1
            let material = appModel?.collisionIsActive == true
                ? collisionMaterial
                : (highlighted ? selectedMaterial : blockMaterial)
            entity.model = ModelComponent(mesh: built[part.id]!, materials: [material])

            let proxy = collisionProxies[part.id] ?? {
                let created = Entity()
                sceneAnchor.addChild(created)
                collisionProxies[part.id] = created
                return created
            }()
            let box = part.mesh.boundingBox
            proxy.position = (box.min + box.max) / 2
            proxy.components.set(CollisionComponent(shapes: [.generateBox(size: box.max - box.min)]))
            proxy.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .kinematic))
        }
        shownParts = parts
        centerOfMass = RenderMesh.centerOfMass(of: parts.map(\.mesh))
        let creaseBox = session.primary.boundingBox
        creaseEntity.position = SIMD3<Float>(
            0,
            (creaseBox.min.y + creaseBox.max.y) / 2,
            (creaseBox.min.z + creaseBox.max.z) / 2
        )
        creaseEntity.scale = SIMD3<Float>(1, 1, max(0.02, creaseBox.max.z - creaseBox.min.z))
        return true
    }

    private static func descriptor(for mesh: RenderMesh) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "PartStudioBody")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        return descriptor
    }
}

/// Full-screen 3D canvas. No text, no docked panel — see RootView for the floating HUD.
struct RealityViewport: View {
    @EnvironmentObject var appModel: AppModel
    /// Owned by RootView so its HUD buttons (hold, undo) can act on the same scene.
    @ObservedObject var entities: ViewportEntities
    /// When on, a one-finger / mouse drag moves the object instead of rotating it.
    var oneFingerPans = false

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
                    drawMode: entities.sketch.isActive,
                    onRotate: { entities.rotate(by: $0) },
                    onRotateBegan: { entities.beginRotate(at: $0) },
                    onRotateEnded: { entities.endRotate() },
                    onPan: { entities.pan(by: $0) },
                    onZoom: { entities.zoom(by: $0) },
                    onTap: { entities.handleTap(at: $0) },
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
        .background(Color.black)
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
