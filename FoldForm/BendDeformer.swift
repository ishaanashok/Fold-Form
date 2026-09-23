import Foundation
import simd

/// Bends an evaluated Part Studio mesh around the crease (local X = 0), matching the piecewise
/// rigid transform specified in the plan (section 5, "BendDeformer"):
///
///     for vertex p:
///         theta = sign(x) * bendAngle
///         distance = abs(x)
///         newX = sign(x) * distance * cos(bendAngle)   // == x * cos(bendAngle)
///         newY = y + distance * sin(bendAngle)          // == y + abs(x) * sin(bendAngle)
///
/// This is a non-destructive *presentation* transform: the CAD model (PartStudio/FeatureTree) stays
/// authored flat, and RealityViewport applies this to the tessellated result every hinge update.
enum BendDeformer {
    static func deform(_ mesh: RenderMesh, bendAngleRadians: Double) -> RenderMesh {
        guard bendAngleRadians != 0 else { return mesh }
        let cosA = Float(cos(bendAngleRadians))
        let sinA = Float(sin(bendAngleRadians))

        let positions: [SIMD3<Float>] = mesh.positions.map { p in
            let newX = p.x * cosA
            let newY = p.y + abs(p.x) * sinA
            return SIMD3<Float>(newX, newY, p.z)
        }

        // Rotate normals by the same local rotation (ignoring the sign(x) discontinuity at the
        // crease itself, which affects a measure-zero set of vertices) so shading stays plausible.
        let normals: [SIMD3<Float>] = zip(mesh.positions, mesh.normals).map { p, n in
            let side: Float = p.x >= 0 ? 1 : -1
            let rotated = SIMD3<Float>(
                n.x * cosA - side * n.y * sinA,
                side * n.x * sinA + n.y * cosA,
                n.z
            )
            return simd_normalize(rotated)
        }

        return RenderMesh(positions: positions, normals: normals, indices: mesh.indices)
    }

    /// World-space endpoints of the bend-axis indicator line, spanning the mesh's Z extent at X=0, Y=0.
    static func creaseIndicatorEndpoints(_ mesh: RenderMesh) -> (SIMD3<Float>, SIMD3<Float>) {
        let box = mesh.boundingBox
        return (SIMD3<Float>(0, 0, box.min.z), SIMD3<Float>(0, 0, box.max.z))
    }
}
