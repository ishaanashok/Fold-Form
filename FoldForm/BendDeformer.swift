import Foundation
import simd

/// Where and how a fold happens: the crease line and the plane it lies in.
struct FoldFrame: Equatable {
    /// A point on the crease line.
    var pivot: SIMD3<Float>
    /// Direction of the crease line.
    var axis: SIMD3<Float>
    /// Normal of the crease plane. The fold bends the block across this plane.
    var normal: SIMD3<Float>

    /// The direction "into the screen" for the fold: the way the crease plane runs away from the
    /// viewer. The block bends toward the opposite side, i.e. toward the viewer.
    var depth: SIMD3<Float> { simd_normalize(simd_cross(axis, normal)) }

    /// True when `other` is close enough that rebuilding the mesh for it would be invisible.
    func isClose(to other: FoldFrame, positionTolerance: Float = 0.0005, directionCosine: Float = 0.99998) -> Bool {
        simd_distance(pivot, other.pivot) < positionTolerance
            && simd_dot(simd_normalize(axis), simd_normalize(other.axis)) > directionCosine
            && simd_dot(simd_normalize(normal), simd_normalize(other.normal)) > directionCosine
    }
}

/// Bends the block smoothly across a crease, the way a thick slab of material really bends.
///
/// `bendAngleRadians` is the change in the angle between the two halves: 0 is flat and 5° means the
/// halves now meet at 175°, like a phone hinge opened to 175°.
///
/// The model is a cylindrical bend. The centre of curvature sits just in front of the block (on the
/// viewer's side) and material is laid around it by its distance from that centre:
///  - the neutral layer in the middle of the thickness keeps its length,
///  - the layer facing the viewer is compressed, the layer facing away is stretched,
///  - beyond the bend zone each half stays rigid and simply tilts by half the bend.
/// Because every point only ever moves toward the viewer and the inside radius stays positive,
/// nothing pushes out of the back and nothing folds through itself, at any angle up to 180°.
///
/// The original procedural solids are coarse, so triangles are first sliced into thin strips across
/// the bend zone; the strips then follow the curve.
enum BendDeformer {
    /// Inside radius of the bend as a multiple of the block's thickness at the crease.
    static let innerRadiusPerThickness: Float = 0.5
    /// Blocks thinner than this are treated as this thick so the bend radius never collapses.
    static let minimumThickness: Float = 0.004
    /// Angular size of one strip in the bend zone.
    static let segmentRadians: Float = 3 * .pi / 180
    static let maxSegments = 60

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    static func deform(_ mesh: RenderMesh, bendAngleRadians: Double, frame: FoldFrame) -> RenderMesh {
        guard abs(bendAngleRadians) > 1e-9, !mesh.positions.isEmpty else { return mesh }

        let theta = Float(min(abs(bendAngleRadians), Double.pi))
        let axis = simd_normalize(frame.axis)
        let normal = simd_normalize(frame.normal)
        let depth = simd_normalize(simd_cross(axis, normal))
        let origin = frame.pivot

        // Thickness of the block where the crease cuts it, measured along the depth direction.
        let (nearest, farthest) = depthRange(of: mesh, origin: origin, normal: normal, depth: depth)
        let thickness = max(farthest - nearest, minimumThickness)
        let innerRadius = innerRadiusPerThickness * thickness
        let neutralRadius = innerRadius + thickness / 2
        let centerDepth = nearest - innerRadius

        // Bend zone: the neutral layer's arc length. Slice it into strips.
        let zoneHalf = neutralRadius * theta / 2
        let segments = min(max(Int((theta / segmentRadians).rounded(.up)), 2), maxSegments)
        let planes = (0...segments).map { -zoneHalf + 2 * zoneHalf * Float($0) / Float(segments) }
        let sliced = slice(mesh, origin: origin, normal: normal, planes: planes)

        let halfTheta = theta / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(sliced.positions.count)
        normals.reserveCapacity(sliced.positions.count)

        for (point, vertexNormal) in zip(sliced.positions, sliced.normals) {
            let d = point - origin
            let along = simd_dot(d, axis)
            let s = simd_dot(d, normal)
            let radius = simd_dot(d, depth) - centerDepth
            // Angle around the centre of curvature; past the zone the half is straight and rigid.
            let phi = min(max(s / neutralRadius, -halfTheta), halfTheta)
            let extra = s - phi * neutralRadius
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let newS = radius * sinPhi + extra * cosPhi
            let newDepth = centerDepth + radius * cosPhi - extra * sinPhi
            positions.append(origin + axis * along + normal * newS + depth * newDepth)

            let nAxis = simd_dot(vertexNormal, axis)
            let nS = simd_dot(vertexNormal, normal)
            let nDepth = simd_dot(vertexNormal, depth)
            let rotated = axis * nAxis + normal * (nS * cosPhi + nDepth * sinPhi) + depth * (-nS * sinPhi + nDepth * cosPhi)
            let length = simd_length(rotated)
            normals.append(length > 1e-6 ? rotated / length : SIMD3<Float>(0, 1, 0))
        }
        return RenderMesh(positions: positions, normals: normals, indices: sliced.indices)
    }

    /// Fold across the plane x = `creaseX` of the block's own coordinates, both halves rising
    /// toward +Y. The block-aligned reference fold used in tests; the app itself folds in camera
    /// space via `deform(_:bendAngleRadians:frame:)`.
    static func deform(_ mesh: RenderMesh, bendAngleRadians: Double, creaseX: Float = 0) -> RenderMesh {
        guard !mesh.positions.isEmpty else { return mesh }
        let frame = FoldFrame(
            pivot: SIMD3<Float>(creaseX, mesh.boundingBox.min.y, 0),
            axis: SIMD3<Float>(0, 0, -1),
            normal: SIMD3<Float>(1, 0, 0)
        )
        return deform(mesh, bendAngleRadians: bendAngleRadians, frame: frame)
    }

    // MARK: - Measuring the crease cross-section

    /// Nearest and farthest depth of the block along the crease plane. If the plane misses the
    /// block entirely, the whole block's depth range is used instead.
    private static func depthRange(of mesh: RenderMesh, origin: SIMD3<Float>, normal: SIMD3<Float>, depth: SIMD3<Float>) -> (Float, Float) {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        func include(_ t: Float) { lo = min(lo, t); hi = max(hi, t) }

        for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let indices = (0..<3).map { Int(mesh.indices[start + $0]) }
            guard indices.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let points = indices.map { mesh.positions[$0] - origin }
            for edge in 0..<3 {
                let a = points[edge], b = points[(edge + 1) % 3]
                let sa = simd_dot(a, normal), sb = simd_dot(b, normal)
                guard (sa <= 0 && sb >= 0) || (sa >= 0 && sb <= 0) else { continue }
                let ta = simd_dot(a, depth), tb = simd_dot(b, depth)
                if abs(sa - sb) < 1e-9 {
                    include(ta); include(tb)
                } else {
                    include(ta + (tb - ta) * (sa / (sa - sb)))
                }
            }
        }
        if lo <= hi { return (lo, hi) }

        for p in mesh.positions { include(simd_dot(p - origin, depth)) }
        return (lo, hi)
    }

    // MARK: - Slicing into strips

    /// Cuts every triangle at each of the (ascending) parallel `planes`, so each piece lies between
    /// two neighbouring planes. Triangles outside the planes' range are left whole.
    private static func slice(_ mesh: RenderMesh, origin: SIMD3<Float>, normal: SIMD3<Float>, planes: [Float]) -> RenderMesh {
        guard mesh.indices.count >= 3 else { return mesh }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let epsilon: Float = 1e-7

        func emit(_ polygon: [Vertex]) {
            guard polygon.count >= 3 else { return }
            let base = UInt32(positions.count)
            positions.append(contentsOf: polygon.map(\.position))
            normals.append(contentsOf: polygon.map(\.normal))
            for offset in 1..<(polygon.count - 1) {
                indices.append(contentsOf: [base, base + UInt32(offset), base + UInt32(offset + 1)])
            }
        }

        for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
            let ids = (0..<3).map { Int(mesh.indices[start + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.normals.count }) else { continue }
            var remaining = ids.map { Vertex(position: mesh.positions[$0], normal: mesh.normals[$0]) }

            for plane in planes {
                let heights = remaining.map { simd_dot($0.position - origin, normal) }
                guard let low = heights.min(), let high = heights.max() else { break }
                if high <= plane + epsilon { break }
                if low >= plane - epsilon { continue }
                let point = origin + normal * plane
                emit(clip(remaining, keepPositive: false, pivot: point, normal: normal))
                remaining = clip(remaining, keepPositive: true, pivot: point, normal: normal)
                if remaining.count < 3 { break }
            }
            emit(remaining)
        }

        guard !positions.isEmpty else { return mesh }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    /// Sutherland-Hodgman clipping against a plane. Intersections keep interpolated normals so the
    /// seam stays shaded consistently with the original face.
    private static func clip(_ polygon: [Vertex], keepPositive: Bool, pivot: SIMD3<Float>, normal: SIMD3<Float>) -> [Vertex] {
        let epsilon: Float = 1e-6
        func distance(_ v: Vertex) -> Float { simd_dot(v.position - pivot, normal) }
        func inside(_ d: Float) -> Bool { keepPositive ? d >= -epsilon : d <= epsilon }

        var output: [Vertex] = []
        guard let first = polygon.last else { return output }
        var previous = first
        var previousDistance = distance(previous)
        var previousInside = inside(previousDistance)

        for current in polygon {
            let currentDistance = distance(current)
            let currentInside = inside(currentDistance)
            if currentInside != previousInside {
                let span = previousDistance - currentDistance
                let fraction = abs(span) > epsilon ? previousDistance / span : 0
                output.append(interpolate(previous, current, fraction: max(0, min(1, fraction))))
            }
            if currentInside { output.append(current) }
            previous = current
            previousDistance = currentDistance
            previousInside = currentInside
        }
        return removeAdjacentDuplicates(output)
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
