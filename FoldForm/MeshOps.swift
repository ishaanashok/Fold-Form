import Foundation
import simd

extension RenderMesh {
    static func merged(_ meshes: [RenderMesh]) -> RenderMesh {
        var result = RenderMesh.empty
        for mesh in meshes {
            let base = UInt32(result.positions.count)
            result.positions += mesh.positions
            result.normals += mesh.normals
            result.indices += mesh.indices.map { $0 + base }
        }
        return result
    }

    func translated(by offset: SIMD3<Float>) -> RenderMesh {
        RenderMesh(positions: positions.map { $0 + offset }, normals: normals, indices: indices)
    }

    /// Moves a mesh built in a plane's own frame (x along `u`, y along `v`, z along `n`) into the
    /// world. `u`, `v`, `n` must be a right-handed set so triangle winding is preserved.
    func placed(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) -> RenderMesh {
        func map(_ p: SIMD3<Float>) -> SIMD3<Float> { u * p.x + v * p.y + n * p.z }
        return RenderMesh(
            positions: positions.map { origin + map($0) },
            normals: normals.map { map($0) },
            indices: indices
        )
    }

    var center: SIMD3<Float> {
        let box = boundingBox
        return (box.min + box.max) / 2
    }

    /// Distance along the ray to the nearest triangle hit (either face), or nil.
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        var nearest: Float?
        for start in stride(from: 0, through: indices.count - 3, by: 3) {
            let i0 = Int(indices[start]), i1 = Int(indices[start + 1]), i2 = Int(indices[start + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let a = positions[i0]
            let e1 = positions[i1] - a, e2 = positions[i2] - a
            let p = simd_cross(direction, e2)
            let det = simd_dot(e1, p)
            guard abs(det) > 1e-12 else { continue }
            let inv = 1 / det
            let t0 = origin - a
            let u = simd_dot(t0, p) * inv
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(t0, e1)
            let v = simd_dot(direction, q) * inv
            guard v >= 0, u + v <= 1 else { continue }
            let t = simd_dot(e2, q) * inv
            if t > 1e-6, t < (nearest ?? .greatestFiniteMagnitude) { nearest = t }
        }
        return nearest
    }
}

// MARK: - Centre of mass

extension RenderMesh {
    /// Volume and volume-weighted centroid of a closed mesh, from the signed tetrahedra each
    /// triangle makes with the origin (divergence theorem). Uniform density, so this is the
    /// centre of mass. Returns nil for empty or degenerate meshes.
    var solidProperties: (volume: Float, centroid: SIMD3<Float>)? {
        var volume: Double = 0
        var moment = SIMD3<Double>(repeating: 0)
        // Work relative to the mesh's own middle so large offsets don't cost precision.
        let anchor = SIMD3<Double>(center)
        for start in stride(from: 0, through: indices.count - 3, by: 3) {
            let i0 = Int(indices[start]), i1 = Int(indices[start + 1]), i2 = Int(indices[start + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let a = SIMD3<Double>(positions[i0]) - anchor
            let b = SIMD3<Double>(positions[i1]) - anchor
            let c = SIMD3<Double>(positions[i2]) - anchor
            let tetra = simd_dot(a, simd_cross(b, c)) / 6
            volume += tetra
            moment += (a + b + c) / 4 * tetra
        }
        guard abs(volume) > 1e-12 else { return nil }
        return (Float(abs(volume)), SIMD3<Float>(moment / volume + anchor))
    }

    /// Centre of mass of several parts together, each weighted by its volume. Falls back to the
    /// middle of the bounding box if none is a proper solid.
    static func centerOfMass(of meshes: [RenderMesh]) -> SIMD3<Float>? {
        var totalVolume: Float = 0
        var weighted = SIMD3<Float>(repeating: 0)
        for mesh in meshes {
            guard let properties = mesh.solidProperties else { continue }
            totalVolume += properties.volume
            weighted += properties.centroid * properties.volume
        }
        if totalVolume > 0 { return weighted / totalVolume }
        let merged = RenderMesh.merged(meshes)
        return merged.positions.isEmpty ? nil : merged.center
    }
}
