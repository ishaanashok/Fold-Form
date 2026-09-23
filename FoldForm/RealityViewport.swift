import SwiftUI
import RealityKit
import Combine
import UIKit

/// Owns the RealityKit entities so `RealityViewport`'s `make`/`update` closures (which only run on
/// the main actor and don't persist their own state) can find and mutate them across updates.
@MainActor
final class ViewportEntities: ObservableObject {
    let partEntity = ModelEntity()
    let creaseEntity = ModelEntity()
    let obstacleEntity = ModelEntity()
    let creaseLabelAnchor = Entity()
    private var collisionSubscription: EventSubscription?
    private var lastAppliedAngle: Double = .nan

    func setUp(in content: inout RealityViewCameraContent, appModel: AppModel) {
        let obstacleSize = SIMD3<Float>(0.03, 0.08, 0.08)
        obstacleEntity.model = ModelComponent(
            mesh: .generateBox(size: obstacleSize),
            materials: [SimpleMaterial(color: .red.withAlphaComponent(0.55), isMetallic: false)]
        )
        obstacleEntity.position = SIMD3<Float>(0.11, 0, 0)
        obstacleEntity.components.set(CollisionComponent(shapes: [.generateBox(size: obstacleSize)]))
        obstacleEntity.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .static))

        creaseEntity.model = ModelComponent(
            mesh: .generateBox(size: SIMD3<Float>(0.002, 0.002, 0.06)),
            materials: [UnlitMaterial(color: .init(red: 1, green: 0.84, blue: 0, alpha: 1))]
        )

        partEntity.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(0.16, 0.02, 0.05))]))
        partEntity.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .kinematic))

        content.entities.append(contentsOf: [partEntity, creaseEntity, obstacleEntity])

        collisionSubscription = content.subscribe(to: CollisionEvents.Began.self) { [weak appModel] event in
            Task { @MainActor in appModel?.reportCollisionBegan() }
        }
    }

    func update(appModel: AppModel) {
        let angle = appModel.hingeInput.hingeAngleRadians
        guard let bodyID = appModel.document.partStudio.orderedBodyIDs.last,
              let solid = appModel.document.partStudio.body(bodyID) else { return }

        let bent = BendDeformer.deform(solid.mesh, bendAngleRadians: angle)
        if let mesh = try? MeshResource.generate(from: [Self.descriptor(for: bent)]) {
            let material: RealityKit.Material = appModel.collisionIsActive
                ? SimpleMaterial(color: .systemRed, isMetallic: true)
                : SimpleMaterial(color: .init(white: 0.75, alpha: 1), isMetallic: true)
            partEntity.model = ModelComponent(mesh: mesh, materials: [material])
        }

        let (a, b) = BendDeformer.creaseIndicatorEndpoints(bent)
        let mid = (a + b) / 2
        creaseEntity.position = mid

        // Rebuild the collision proxy only when the angle moved meaningfully, per plan guidance
        // ("rebuild or reposition the proxy only when the hinge angle changes beyond a small
        // threshold, not blindly every render frame").
        if abs(angle - lastAppliedAngle) > (1.0 * .pi / 180) {
            lastAppliedAngle = angle
            let box = bent.boundingBox
            let size = box.max - box.min
            let center = (box.max + box.min) / 2
            partEntity.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
            partEntity.position = center
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
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                Text("Bend axis: along device crease")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                StatusBadgeView()
            }
            .padding(.top, 8)
        }
    }
}
