import Foundation
import simd

/// A geometric location, independent of the duplicated vertices used for flat shading.
enum MeshFeatureSelection: Equatable {
    case vertex(SIMD3<Float>)
    case edge(SIMD3<Float>, SIMD3<Float>)

    var anchor: SIMD3<Float> {
        switch self {
        case .vertex(let point): point
        case .edge(let a, let b): (a + b) / 2
        }
    }
}

/// Picks silhouette and face-boundary edges from welded topology, excluding triangulation seams.
enum MeshFeaturePicker {
    static func pick(mesh: RenderMesh, rig: CameraRig, size: CGSize, point: CGPoint) -> MeshFeatureSelection? {
        let topology = MeshTouchUp.Topology(mesh)
        let sharp = topology.edgeFaces().filter { _, faces in
            guard faces.count == 2, let a = topology.normal(faces[0]), let b = topology.normal(faces[1]) else { return false }
            return simd_dot(a, b) < 0.94
        }
        let vertexIDs = Set(sharp.keys.flatMap { [$0.a, $0.b] })
        var nearestVertex: (point: SIMD3<Float>, distance: CGFloat)?
        for id in vertexIDs {
            let world = topology.points[id]
            guard let projected = rig.project(world, in: size), visible(world, mesh: mesh, rig: rig, size: size) else { continue }
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            if distance < 14, distance < nearestVertex?.distance ?? .infinity { nearestVertex = (world, distance) }
        }
        if let vertex = nearestVertex { return .vertex(vertex.point) }

        var nearestEdge: (a: SIMD3<Float>, b: SIMD3<Float>, distance: CGFloat)?
        for edge in sharp.keys {
            let a = topology.points[edge.a], b = topology.points[edge.b]
            guard let start = rig.project(a, in: size), let end = rig.project(b, in: size),
                  visible((a + b) / 2, mesh: mesh, rig: rig, size: size) else { continue }
            let vx = end.x - start.x, vy = end.y - start.y
            let lengthSquared = vx * vx + vy * vy
            guard lengthSquared > 1 else { continue }
            let t = min(max(((point.x - start.x) * vx + (point.y - start.y) * vy) / lengthSquared, 0), 1)
            let distance = hypot(point.x - start.x - t * vx, point.y - start.y - t * vy)
            if distance < 11, distance < nearestEdge?.distance ?? .infinity { nearestEdge = (a, b, distance) }
        }
        return nearestEdge.map { .edge($0.a, $0.b) }
    }

    private static func visible(_ world: SIMD3<Float>, mesh: RenderMesh, rig: CameraRig, size: CGSize) -> Bool {
        guard let projected = rig.project(world, in: size) else { return false }
        let ray = rig.ray(at: projected, in: size)
        guard let hit = mesh.raycast(origin: ray.origin, direction: ray.direction) else { return true }
        return hit >= simd_distance(ray.origin, world) - 0.0005
    }
}
