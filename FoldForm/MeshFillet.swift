import Foundation
import simd

/// Rebuilds one convex corner of a prism. The edge form rounds its full extrusion edge; the
/// vertex form fades that corner into the original profile across a short distance from one cap.
enum MeshFillet {
    static func radius(forBend bend: Double, mesh: RenderMesh, selection: MeshFeatureSelection) -> Float {
        prepared(mesh: mesh, selection: selection, bend: bend)?.radius ?? 0
    }

    static func make(mesh: RenderMesh, selection: MeshFeatureSelection, bend: Double) -> RenderMesh? {
        guard let fillet = prepared(mesh: mesh, selection: selection, bend: bend) else { return nil }
        switch selection {
        case .edge:
            guard let outline = rounded(fillet.loop, at: fillet.corner, radius: fillet.radius) else { return nil }
            return MeshTouchUp.rebuildPrism(fillet.profile, loops: [outline])
        case .vertex(let vertex):
            let height = simd_dot(vertex - fillet.profile.origin, fillet.profile.n)
            guard height < 1e-4 || fillet.profile.height - height < 1e-4 else { return nil }
            return tapered(profile: fillet.profile, loop: fillet.loop, corner: fillet.corner,
                           radius: fillet.radius, atTop: height > fillet.profile.height / 2)
        }
    }

    private struct PreparedFillet {
        var profile: PrismProfile
        var loop: [SIMD2<Float>]
        var corner: Int
        var radius: Float
    }

    private static func prepared(mesh: RenderMesh, selection: MeshFeatureSelection, bend: Double) -> PreparedFillet? {
        let angle = HingeInputManager.snappedBend(HingeInputManager.clampedBend(bend))
        guard angle > FoldSession.flatThresholdRadians else { return nil }
        let box = mesh.boundingBox
        let size = box.max - box.min
        let smallest = min(size.x, size.y, size.z)
        guard smallest.isFinite, smallest > 1e-6 else { return nil }
        let desired = smallest * BendDeformer.innerRadiusPerThickness * Float(angle / .pi)
        guard desired > 1e-6 else { return nil }
        let profile: PrismProfile?
        switch selection {
        case .edge(let a, let b):
            let axis = b - a
            guard simd_length(axis) > 1e-6 else { return nil }
            profile = MeshTouchUp.prismProfile(of: mesh, axis: axis)
        case .vertex:
            profile = MeshTouchUp.prismProfile(of: mesh)
        }
        guard let profile, profile.loops.count == 1, profile.height > 1e-6 else { return nil }
        let loop = counterClockwise(profile.loops[0])
        let anchor = selection.anchor
        let projected = SIMD2(simd_dot(anchor, profile.u), simd_dot(anchor, profile.v))
        guard let corner = loop.indices.min(by: { simd_distance(loop[$0], projected) < simd_distance(loop[$1], projected) }),
              simd_distance(loop[corner], projected) < max(desired * 0.1, 1e-5) else { return nil }
        let previous = loop[(corner + loop.count - 1) % loop.count]
        let current = loop[corner]
        let next = loop[(corner + 1) % loop.count]
        let incoming = current - previous, outgoing = next - current
        guard incoming.x * outgoing.y - incoming.y * outgoing.x > 1e-8 else { return nil }
        let a = simd_normalize(previous - current), b = simd_normalize(next - current)
        let halfAngle = acos(min(max(simd_dot(a, b), -1), 1)) / 2
        guard halfAngle > 0.05 else { return nil }
        let maxSetback = min(simd_length(incoming), simd_length(outgoing)) * 0.45
        let radius = min(desired, maxSetback * tan(halfAngle), profile.height * 0.45)
        guard radius > 1e-6 else { return nil }
        return PreparedFillet(profile: profile, loop: loop, corner: corner, radius: radius)
    }

    private static func counterClockwise(_ loop: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let area = loop.indices.reduce(Float(0)) { $0 + loop[$1].x * loop[($1 + 1) % loop.count].y - loop[($1 + 1) % loop.count].x * loop[$1].y }
        return area >= 0 ? loop : Array(loop.reversed())
    }

    private static func rounded(_ loop: [SIMD2<Float>], at index: Int, radius: Float) -> [SIMD2<Float>]? {
        let corner = loop[index]
        let a = simd_normalize(loop[(index + loop.count - 1) % loop.count] - corner)
        let b = simd_normalize(loop[(index + 1) % loop.count] - corner)
        let halfAngle = acos(min(max(simd_dot(a, b), -1), 1)) / 2
        guard halfAngle > 0.05, let bisector = safeUnit(a + b) else { return nil }
        let centre = corner + bisector * (radius / sin(halfAngle))
        let setback = radius / tan(halfAngle)
        let start = corner + a * setback - centre
        let end = corner + b * setback - centre
        let startAngle = atan2(start.y, start.x)
        var endAngle = atan2(end.y, end.x)
        if endAngle <= startAngle { endAngle += 2 * .pi }
        guard endAngle - startAngle < .pi + 0.01 else { return nil }
        var result: [SIMD2<Float>] = []
        for i in loop.indices {
            if i == index {
                for segment in 0...8 {
                    let angle = startAngle + (endAngle - startAngle) * Float(segment) / 8
                    result.append(centre + radius * SIMD2(cos(angle), sin(angle)))
                }
            } else { result.append(loop[i]) }
        }
        return result
    }

    private static func safeUnit(_ vector: SIMD2<Float>) -> SIMD2<Float>? {
        let length = simd_length(vector)
        return length > 1e-6 ? vector / length : nil
    }

    private static func tapered(profile: PrismProfile, loop: [SIMD2<Float>], corner: Int, radius: Float, atTop: Bool) -> RenderMesh? {
        let h = profile.height
        let r = radius
        let small = r * 0.05
        let levels: [(z: Float, radius: Float)]
        if atTop {
            levels = [(0, small), (h - r, small), (h - r * 0.75, r * 0.25),
                      (h - r * 0.5, r * 0.5), (h - r * 0.25, r * 0.75), (h, r)]
        } else {
            levels = [(0, r), (r * 0.25, r * 0.75), (r * 0.5, r * 0.5),
                      (r * 0.75, r * 0.25), (r, small), (h, small)]
        }
        let rings = levels.compactMap { rounded(loop, at: corner, radius: $0.radius) }
        guard rings.count == levels.count, let count = rings.first?.count else { return nil }
        var result = RenderMesh.empty
        func world(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> {
            profile.origin + profile.u * p.x + profile.v * p.y + profile.n * z
        }
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-12 else { return }
            let base = UInt32(result.positions.count)
            result.positions += [a, b, c]
            result.normals += [normal / length, normal / length, normal / length]
            result.indices += [base, base + 1, base + 2]
        }
        for cap in [0, levels.count - 1] {
            let outline = rings[cap].map { SIMD2<Double>(Double($0.x), Double($0.y)) }
            let tris = Triangulator.triangulate(outline)
            guard tris.count >= 3 else { return nil }
            for i in stride(from: 0, to: tris.count, by: 3) {
                let a = world(rings[cap][tris[i]], levels[cap].z)
                let b = world(rings[cap][tris[i + 1]], levels[cap].z)
                let c = world(rings[cap][tris[i + 2]], levels[cap].z)
                if cap == 0 { triangle(a, c, b) } else { triangle(a, b, c) }
            }
        }
        for level in 0..<(levels.count - 1) {
            for i in 0..<count {
                let j = (i + 1) % count
                let a = world(rings[level][i], levels[level].z)
                let b = world(rings[level][j], levels[level].z)
                let c = world(rings[level + 1][j], levels[level + 1].z)
                let d = world(rings[level + 1][i], levels[level + 1].z)
                triangle(a, b, c)
                triangle(a, c, d)
            }
        }
        return result
    }
}
