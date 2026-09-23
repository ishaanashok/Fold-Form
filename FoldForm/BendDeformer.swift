import Foundation
import simd

/// Applies a non-destructive, piecewise-rigid bend around the document's local crease.
///
/// Coordinate contract:
/// - local X is signed distance from the crease;
/// - local Y is the neutral-plane direction;
/// - local Z runs along the crease.
///
/// The original procedural solids are intentionally coarse. Before bending, triangles that cross
/// x == 0 are split at the crease so a cap or side wall can never stretch across the fold as one
/// triangle. That seam is the important difference between a real two-sided bend and a mesh that
/// merely appears to rotate at its ends.
enum BendDeformer {
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    static func deform(_ mesh: RenderMesh, bendAngleRadians: Double) -> RenderMesh {
        guard abs(bendAngleRadians) > 1e-9, !mesh.positions.isEmpty else { return mesh }

        let splitMesh = splitAtCrease(mesh)
        let cosA = Float(cos(bendAngleRadians))
        let sinA = Float(sin(bendAngleRadians))

        let positions = splitMesh.positions.map { point in
            let side: Float = point.x < 0 ? -1 : 1
            // Rotate each side rigidly by an equal and opposite angle around the neutral axis.
            let newX = point.x * cosA - side * point.y * sinA
            let newY = side * point.x * sinA + point.y * cosA
            return SIMD3<Float>(newX, newY, point.z)
        }

        let normals = zip(splitMesh.positions, splitMesh.normals).map { point, normal in
            let side: Float = point.x < 0 ? -1 : 1
            let rotated = SIMD3<Float>(
                normal.x * cosA - side * normal.y * sinA,
                side * normal.x * sinA + normal.y * cosA,
                normal.z
            )
            let length = simd_length(rotated)
            return length > 1e-6 ? rotated / length : SIMD3<Float>(0, 1, 0)
        }

        return RenderMesh(positions: positions, normals: normals, indices: splitMesh.indices)
    }

    /// Returns a crease line centered on the neutral plane, spanning the evaluated mesh in Z.
    static func creaseIndicatorEndpoints(_ mesh: RenderMesh) -> (SIMD3<Float>, SIMD3<Float>) {
        let box = mesh.boundingBox
        return (SIMD3<Float>(0, 0, box.min.z), SIMD3<Float>(0, 0, box.max.z))
    }

    // MARK: - Crease topology

    private static func splitAtCrease(_ mesh: RenderMesh) -> RenderMesh {
        guard mesh.indices.count >= 3 else { return mesh }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for triangleStart in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let indexA = Int(mesh.indices[triangleStart])
            let indexB = Int(mesh.indices[triangleStart + 1])
            let indexC = Int(mesh.indices[triangleStart + 2])
            guard indexA < mesh.positions.count, indexB < mesh.positions.count, indexC < mesh.positions.count,
                  indexA < mesh.normals.count, indexB < mesh.normals.count, indexC < mesh.normals.count else { continue }

            let triangle = [
                Vertex(position: mesh.positions[indexA], normal: mesh.normals[indexA]),
                Vertex(position: mesh.positions[indexB], normal: mesh.normals[indexB]),
                Vertex(position: mesh.positions[indexC], normal: mesh.normals[indexC])
            ]

            appendClippedPolygon(triangle, keepPositive: false, positions: &positions, normals: &normals, indices: &indices)
            appendClippedPolygon(triangle, keepPositive: true, positions: &positions, normals: &normals, indices: &indices)
        }

        guard !positions.isEmpty else { return mesh }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    private static func appendClippedPolygon(
        _ polygon: [Vertex],
        keepPositive: Bool,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let clipped = clip(polygon, keepPositive: keepPositive)
        guard clipped.count >= 3 else { return }

        let base = UInt32(positions.count)
        positions.append(contentsOf: clipped.map(\.position))
        normals.append(contentsOf: clipped.map(\.normal))
        for offset in 1..<(clipped.count - 1) {
            indices.append(contentsOf: [base, base + UInt32(offset), base + UInt32(offset + 1)])
        }
    }

    /// Sutherland-Hodgman clipping against the x == 0 plane. Intersections retain interpolated
    /// normals so the resulting seam remains shaded consistently with the original face.
    private static func clip(_ polygon: [Vertex], keepPositive: Bool) -> [Vertex] {
        let epsilon: Float = 1e-6
        var output: [Vertex] = []
        guard let first = polygon.last else { return output }
        var previous = first
        var previousInside = isInside(previous.position.x, keepPositive: keepPositive, epsilon: epsilon)

        for current in polygon {
            let currentInside = isInside(current.position.x, keepPositive: keepPositive, epsilon: epsilon)
            if currentInside != previousInside {
                let denominator = current.position.x - previous.position.x
                let fraction = abs(denominator) > epsilon ? (-previous.position.x / denominator) : 0
                output.append(interpolate(previous, current, fraction: max(0, min(1, fraction))))
            }
            if currentInside { output.append(current) }
            previous = current
            previousInside = currentInside
        }
        return removeAdjacentDuplicates(output)
    }

    private static func isInside(_ x: Float, keepPositive: Bool, epsilon: Float) -> Bool {
        keepPositive ? x >= -epsilon : x <= epsilon
    }

    private static func interpolate(_ lhs: Vertex, _ rhs: Vertex, fraction: Float) -> Vertex {
        let position = lhs.position + (rhs.position - lhs.position) * fraction
        let normal = lhs.normal + (rhs.normal - lhs.normal) * fraction
        let length = simd_length(normal)
        return Vertex(position: position, normal: length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0))
    }

    private static func removeAdjacentDuplicates(_ vertices: [Vertex]) -> [Vertex] {
        guard !vertices.isEmpty else { return [] }
        var result: [Vertex] = [vertices[0]]
        for vertex in vertices.dropFirst() {
            if simd_distance_squared(result[result.count - 1].position, vertex.position) > 1e-12 {
                result.append(vertex)
            }
        }
        if result.count > 1, simd_distance_squared(result[0].position, result[result.count - 1].position) <= 1e-12 {
            result.removeLast()
        }
        return result
    }
}
