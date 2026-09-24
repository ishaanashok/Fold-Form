import SwiftUI
import RealityKit
import Combine
import UIKit

struct ViewAxes: Equatable {
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
}

/// Owns the RealityKit scene for the part: one solid block that folds where the phone's crease is
/// on screen, in whatever orientation the block is being viewed. Folds can be held and stacked
/// (see FoldSession). All app chrome (angle readout, buttons) lives in RootView as a floating HUD.
@MainActor
final class ViewportEntities: ObservableObject {
    private let sceneAnchor = AnchorEntity(world: .zero)
    private let partEntity = ModelEntity()
    private let cameraEntity = PerspectiveCamera()
    private let keyLight = DirectionalLight()

    private var rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
    private var viewportSize = CGSize(width: 951, height: 669)
    private var crease = ScreenCrease.centeredVertical

    private weak var appModel: AppModel?
    private var hingeSubscription: AnyCancellable?
    private var isSetUp = false

    /// Folds that have been held, and whether the shape is currently frozen.
    private var session: FoldSession?
    /// The camera's axes, for the view cube to mirror.
    @Published private(set) var viewAxes = ViewAxes(right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1))
    private var snapTask: Task<Void, Never>?
    @Published private(set) var isHolding = false
    @Published private(set) var foldCount = 0

    /// Everything that determines the displayed mesh, so a rebuild only happens when it changed.
    private struct BuildKey {
        var bend: Double
        var frame: FoldFrame
        var revision: Int
        var holding: Bool
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

    private static let bendThreshold = 0.05 * .pi / 180
    /// At most ~20 mesh rebuilds a second while dragging; the last state is always applied.
    private static let minRebuildInterval: CFAbsoluteTime = 0.05

    func setUp(in content: inout RealityViewCameraContent, appModel: AppModel) {
        guard !isSetUp else { return }
        isSetUp = true
        self.appModel = appModel

        sceneAnchor.addChild(partEntity)
        content.add(sceneAnchor)

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
    }

    // MARK: Camera

    private func initialFramingBounds(appModel: AppModel) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(-0.03, -0.01, -0.03)
        var hi = SIMD3<Float>(0.03, 0.01, 0.03)
        if let bodyID = appModel.document.partStudio.orderedBodyIDs.last,
           let solid = appModel.document.partStudio.body(bodyID) {
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
        let axes = ViewAxes(right: rig.right, up: rig.up, forward: rig.forward)
        DispatchQueue.main.async { [weak self] in self?.viewAxes = axes }
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
                self.rig.yaw = start.yaw + (target.yaw - start.yaw) * eased
                self.rig.pitch = start.pitch + (target.pitch - start.pitch) * eased
                self.cameraMoved()
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func rotate(by delta: CGSize) {
        snapTask?.cancel()
        rig.rotate(dx: Float(delta.width), dy: Float(delta.height))
        cameraMoved()
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

    func updateLayout(size: CGSize, crease: ScreenCrease) {
        guard size.width > 0, size.height > 0 else { return }
        viewportSize = size
        self.crease = crease
        refreshFold()
    }

    // MARK: Folding

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
        if key.revision != last.revision || key.holding != last.holding { return true }
        // A held shape ignores both the hinge and the camera.
        if key.holding { return false }
        if abs(key.bend - last.bend) > Self.bendThreshold { return true }
        // Moving the crease across a flat block changes nothing visible, so only follow it once
        // there is an actual bend.
        return key.bend > 1e-4 && !key.frame.isClose(to: last.frame)
    }

    private func refreshFold(bend bendOverride: Double? = nil) {
        guard let appModel,
              let bodyID = appModel.document.partStudio.orderedBodyIDs.last,
              let solid = appModel.document.partStudio.body(bodyID) else { return }

        // A different block from the document starts a fresh set of folds.
        if session == nil || session?.source != solid.mesh {
            session = FoldSession(source: solid.mesh)
            lastBuild = nil
            publishSession()
        }
        let bend = bendOverride ?? appModel.hingeInput.bendAngleRadians
        // Back at flat releases a hold.
        if session?.bendChanged(bend) == true { publishSession() }

        let key = BuildKey(bend: bend, frame: currentFrame(), revision: session?.revision ?? 0, holding: session?.isHolding ?? false)
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
        let shape = session.displayedMesh(bend: key.bend, frame: key.frame)
        guard let mesh = try? MeshResource.generate(from: [Self.descriptor(for: shape)]) else { return false }
        partEntity.model = ModelComponent(mesh: mesh, materials: [blockMaterial])
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
                    onRotate: { entities.rotate(by: $0) },
                    onPan: { entities.pan(by: $0) },
                    onZoom: { entities.zoom(by: $0) }
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
