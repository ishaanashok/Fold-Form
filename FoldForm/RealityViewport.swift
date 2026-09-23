import SwiftUI
import RealityKit
import Combine
import UIKit

/// Owns a stable, full-screen RealityKit hierarchy for the part and its crease indicator. Pure 3D
/// content only — no obstacle prop, no text overlay. All app chrome (angle readout, tool drawer)
/// lives in RootView (FoldFormApp.swift) as a floating HUD over this view.
@MainActor
final class ViewportEntities: ObservableObject {
    private let sceneAnchor = AnchorEntity(world: .zero)
    private let partRoot = Entity()

    private let partEntity = ModelEntity()
    private let creaseEntity = ModelEntity()
    private let cameraEntity = PerspectiveCamera()
    private let keyLight = DirectionalLight()

    private var lastAppliedAngle: Double = .nan
    private var lastAppliedBodyID: UUID?
    private var cachedMesh: MeshResource?
    private var isSetUp = false

    func setUp(in content: inout RealityViewCameraContent, appModel: AppModel) {
        guard !isSetUp else { return }
        isSetUp = true

        // The crease indicator marks the fold line only — there is no separate hinge prop. The
        // part itself splits and rotates about this line (see BendDeformer), the way a real sheet
        // of material creases, rather than showing any mechanical joint.
        creaseEntity.model = ModelComponent(
            mesh: .generateBox(size: SIMD3<Float>(0.002, 0.002, 0.06)),
            materials: [UnlitMaterial(color: .init(red: 1, green: 0.84, blue: 0, alpha: 1))]
        )

        partRoot.addChild(partEntity)
        partRoot.addChild(creaseEntity)
        sceneAnchor.addChild(partRoot)
        content.add(sceneAnchor)

        // `.virtual` alone doesn't place or frame a camera — without an explicit PerspectiveCamera
        // entity the part rendered off-frame or too small to see. Frame it from the actual initial
        // geometry so any quick-start profile (thin plate, box, cylinder, ...) starts centered and
        // legible, the way a modeling tool frames its default starting shape.
        keyLight.light = DirectionalLightComponent(color: .white, intensity: 4000, isRealWorldProxy: false)
        keyLight.look(at: .zero, from: SIMD3<Float>(0.2, 0.3, 0.25), relativeTo: nil)
        content.add(keyLight)

        content.add(cameraEntity)
        content.camera = .virtual
        frameCamera(around: initialFramingBounds(appModel: appModel))

        // Deliberately no `content.cameraTarget`: setting it was found (empirically) to silently
        // override this manual placement and snap the camera into a useless close-up. `.orbit`
        // camera controls (applied by RealityViewport below) work fine without it — one-finger
        // drag orbits, two-finger drag pans, pinch zooms.
    }

    /// Bounding box at launch, used once to place the camera. Bending changes the part's silhouette
    /// only modestly (see BendDeformer), so a single initial framing stays reasonable through the
    /// whole 0°–90° range rather than fighting the user's own orbit/zoom.
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
        // A 3/4 diagonal viewing angle (à la a modeling tool's default view) so width, thickness,
        // and length are all legible at once, instead of face-on or edge-on to the thin plate.
        let direction = simd_normalize(SIMD3<Float>(1.1, 0.85, 1.4))
        let fovRadians: Float = 60 * .pi / 180
        let distance = (radius / tan(fovRadians / 2)) * 1.35
        cameraEntity.look(at: center, from: center + direction * distance, relativeTo: nil)
    }

    func update(appModel: AppModel) {
        let angle = appModel.hingeInput.hingeAngleRadians
        guard let bodyID = appModel.document.partStudio.orderedBodyIDs.last,
              let solid = appModel.document.partStudio.body(bodyID) else { return }

        // RealityView updates can be caused by any published UI state. Only regenerate the mesh
        // when the hinge or evaluated body actually changed; a bare collision-state flip just
        // swaps the material on the mesh we already have.
        let angleThreshold = 0.15 * .pi / 180
        let bodyChanged = bodyID != lastAppliedBodyID
        let angleChanged = !lastAppliedAngle.isFinite || abs(angle - lastAppliedAngle) > angleThreshold
        guard bodyChanged || angleChanged || cachedMesh == nil else { return }

        let bent = BendDeformer.deform(solid.mesh, bendAngleRadians: angle)
        if let mesh = try? MeshResource.generate(from: [Self.descriptor(for: bent)]) {
            cachedMesh = mesh
        }
        guard let mesh = cachedMesh else { return }

        let material: RealityKit.Material = appModel.collisionIsActive
            ? SimpleMaterial(color: .systemRed, isMetallic: true)
            : SimpleMaterial(color: .init(white: 0.75, alpha: 1), isMetallic: true)
        partEntity.model = ModelComponent(mesh: mesh, materials: [material])

        // Both endpoints are computed in the same local coordinates as the deformed mesh. Since
        // creaseEntity is a child of partRoot, this line cannot drift when the panel arrangement
        // changes or when the mesh bounding box grows in Y during a bend.
        let (a, b) = BendDeformer.creaseIndicatorEndpoints(bent)
        creaseEntity.position = (a + b) / 2
        let creaseLength = max(0.001, b.z - a.z)
        creaseEntity.scale = SIMD3<Float>(1, 1, creaseLength / 0.06)

        lastAppliedAngle = angle
        lastAppliedBodyID = bodyID
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
    @StateObject private var entities = ViewportEntities()

    var body: some View {
        RealityView { (content: inout RealityViewCameraContent) in
            entities.setUp(in: &content, appModel: appModel)
        } update: { (_: inout RealityViewCameraContent) in
            entities.update(appModel: appModel)
        }
        // One-finger drag orbits, two-finger drag pans, pinch zooms.
        .realityViewCameraControls(.orbit)
        .background(Color.black)
        .ignoresSafeArea()
    }
}
