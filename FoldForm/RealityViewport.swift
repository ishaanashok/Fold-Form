import SwiftUI
import RealityKit
import Combine
import UIKit

/// Owns a stable RealityKit hierarchy for the part, crease, and collision proxy. The hierarchy is
/// deliberately independent from ArrangementView: adaptive split-screen layout may resize the
/// viewport, but it must never translate the modeled part or its local bend axis.
@MainActor
final class ViewportEntities: ObservableObject {
    private let sceneAnchor = AnchorEntity(world: .zero)
    private let partRoot = Entity()
    private let collisionProxy = Entity()

    private let partEntity = ModelEntity()
    private let creaseEntity = ModelEntity()
    private let obstacleEntity = ModelEntity()

    private var collisionSubscription: EventSubscription?
    private var collisionEndedSubscription: EventSubscription?
    private let cameraEntity = PerspectiveCamera()
    private let keyLight = DirectionalLight()

    private var lastAppliedAngle: Double = .nan
    private var lastAppliedBodyID: UUID?
    private var lastCollisionActive = false
    private var cachedMesh: MeshResource?
    private var isSetUp = false

    func setUp(in content: inout RealityViewCameraContent, appModel: AppModel) {
        guard !isSetUp else { return }
        isSetUp = true

        // The wall is above the flat plate and reaches it in a repeatable mid-range bend.
        let obstacleSize = SIMD3<Float>(0.055, 0.012, 0.06)
        obstacleEntity.model = ModelComponent(
            mesh: .generateBox(size: obstacleSize),
            materials: [SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.55), isMetallic: false)]
        )
        obstacleEntity.position = SIMD3<Float>(0.04, 0.077, 0)
        obstacleEntity.components.set(CollisionComponent(shapes: [.generateBox(size: obstacleSize)]))
        obstacleEntity.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .static))

        creaseEntity.model = ModelComponent(
            mesh: .generateBox(size: SIMD3<Float>(0.002, 0.002, 0.06)),
            materials: [UnlitMaterial(color: .init(red: 1, green: 0.84, blue: 0, alpha: 1))]
        )

        // All part-space elements share this origin. The crease is not a sibling in world space,
        // and the part is never recentered from its changing bent bounding box.
        partRoot.addChild(partEntity)
        partRoot.addChild(creaseEntity)
        partRoot.addChild(collisionProxy)
        sceneAnchor.addChild(partRoot)
        sceneAnchor.addChild(obstacleEntity)
        content.add(sceneAnchor)

        // `.virtual` alone doesn't place or frame a camera — without an explicit PerspectiveCamera
        // entity the part rendered off-frame or too small to see. Frame it from the actual initial
        // geometry so any quick-start profile (thin plate, box, cylinder, ...) starts centered and
        // legible, the way a 3D tool's default view frames its starting shape.
        keyLight.light = DirectionalLightComponent(color: .white, intensity: 4000, isRealWorldProxy: false)
        keyLight.look(at: .zero, from: SIMD3<Float>(0.2, 0.3, 0.25), relativeTo: nil)
        content.add(keyLight)

        content.add(cameraEntity)
        content.camera = .virtual
        frameCamera(around: initialFramingBounds(appModel: appModel))

        collisionProxy.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(0.12, 0.016, 0.05))]))
        collisionProxy.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .kinematic))
        collisionSubscription = content.subscribe(to: CollisionEvents.Began.self, on: collisionProxy) { [weak appModel] _ in
            Task { @MainActor [weak appModel] in appModel?.reportCollisionBegan() }
        }
        collisionEndedSubscription = content.subscribe(to: CollisionEvents.Ended.self, on: collisionProxy) { [weak appModel] _ in
            Task { @MainActor [weak appModel] in appModel?.reportCollisionEnded() }
        }
    }

    /// Bounding box (part + obstacle) at launch, used once to place the camera. Bending changes the
    /// part's silhouette only modestly (see BendDeformer), so a single initial framing stays
    /// reasonable through the whole 0°–90° range rather than fighting the user's own orbit/zoom.
    private func initialFramingBounds(appModel: AppModel) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(-0.03, -0.01, -0.03)
        var hi = SIMD3<Float>(0.03, 0.01, 0.03)
        if let bodyID = appModel.document.partStudio.orderedBodyIDs.last,
           let solid = appModel.document.partStudio.body(bodyID) {
            let box = solid.mesh.boundingBox
            lo = simd_min(lo, box.min)
            hi = simd_max(hi, box.max)
        }
        let obstacleHalf = SIMD3<Float>(0.055, 0.012, 0.06) / 2
        let obstaclePos = SIMD3<Float>(0.04, 0.077, 0)
        lo = simd_min(lo, obstaclePos - obstacleHalf)
        hi = simd_max(hi, obstaclePos + obstacleHalf)
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
        // when the hinge or evaluated body actually changed; collision state only changes material.
        let angleThreshold = 0.15 * .pi / 180
        let bodyChanged = bodyID != lastAppliedBodyID
        let angleChanged = !lastAppliedAngle.isFinite || abs(angle - lastAppliedAngle) > angleThreshold
        let collisionChanged = appModel.collisionIsActive != lastCollisionActive
        guard bodyChanged || angleChanged || collisionChanged || cachedMesh == nil else { return }

        let bent = BendDeformer.deform(solid.mesh, bendAngleRadians: angle)
        if bodyChanged || angleChanged || cachedMesh == nil,
           let mesh = try? MeshResource.generate(from: [Self.descriptor(for: bent)]) {
            cachedMesh = mesh
        }
        guard let mesh = cachedMesh else { return }

        let material: RealityKit.Material = appModel.collisionIsActive
            ? SimpleMaterial(color: .systemRed, isMetallic: true)
            : SimpleMaterial(color: .init(white: 0.75, alpha: 1), isMetallic: true)
        partEntity.model = ModelComponent(mesh: mesh, materials: [material])
        lastCollisionActive = appModel.collisionIsActive

        // Both endpoints are computed in the same local coordinates as the deformed mesh. Since
        // creaseEntity is a child of partRoot, this line cannot drift when the panel arrangement
        // changes or when the mesh bounding box grows in Y during a bend.
        let (a, b) = BendDeformer.creaseIndicatorEndpoints(bent)
        creaseEntity.position = (a + b) / 2
        let creaseLength = max(0.001, b.z - a.z)
        creaseEntity.scale = SIMD3<Float>(1, 1, creaseLength / 0.06)

        if bodyChanged || angleChanged {
            lastAppliedAngle = angle
            lastAppliedBodyID = bodyID
            let box = bent.boundingBox
            collisionProxy.position = (box.max + box.min) / 2
            collisionProxy.components.set(CollisionComponent(shapes: [.generateBox(size: box.max - box.min)]))
        }
    }

    private static func descriptor(for mesh: RenderMesh) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "PartStudioBody")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        return descriptor
    }
}

struct RealityViewport: View {
    @EnvironmentObject var appModel: AppModel
    @StateObject private var entities = ViewportEntities()

    var body: some View {
        RealityView { (content: inout RealityViewCameraContent) in
            entities.setUp(in: &content, appModel: appModel)
        } update: { (_: inout RealityViewCameraContent) in
            entities.update(appModel: appModel)
        }
        .realityViewCameraControls(.orbit)
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                Text("Bend axis: along device crease")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                StatusBadgeView()
                Text("Obstacle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            .padding(.top, 8)
        }
        .background(Color.black)
    }
}
