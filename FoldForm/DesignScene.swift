import Foundation
import simd

/// One body of the design, as an axis-aligned block. Boxes and cylinders (extrusions of a rectangle
/// or a circle along a world axis) can be resized and moved; anything else keeps its shape and only
/// serves as something for the others to line up with.
struct DesignPart {
    enum Kind { case box, cylinder, other }

    var id: UUID
    var kind: Kind
    var min: SIMD3<Float>
    var max: SIMD3<Float>
    var mesh: RenderMesh
    var volume: Float
    /// The extrusion axis (0 x, 1 y, 2 z) for boxes and cylinders, otherwise -1.
    var axis: Int
    fileprivate var profile: PrismProfile?

    var size: SIMD3<Float> { max - min }
    var center: SIMD3<Float> { (min + max) / 2 }
    var isMovable: Bool { kind != .other }

    /// The part rebuilt to fill `lo...hi`: a box, or a cylinder with the given block as its bounds.
    func rebuilt(lo: SIMD3<Float>, hi: SIMD3<Float>) -> RenderMesh? {
        guard kind != .other else { return nil }
        // A box is rebuilt exactly, straight from its bounds: reusing the outline of a slightly
        // skewed original would carry the skew into the new part.
        if kind == .box {
            let size = hi - lo
            guard size.x > 1e-6, size.y > 1e-6, size.z > 1e-6 else { return nil }
            return GeometryBuilder.box(width: Double(size.x), height: Double(size.y), depth: Double(size.z)).translated(by: (lo + hi) / 2)
        }
        guard var profile else { return nil }
        let n = profile.n
        let a = simd_dot(lo, n), b = simd_dot(hi, n)
        profile.origin = n * Swift.min(a, b)
        profile.height = abs(b - a)
        let p0 = SIMD2(simd_dot(lo, profile.u), simd_dot(lo, profile.v))
        let p1 = SIMD2(simd_dot(hi, profile.u), simd_dot(hi, profile.v))
        let low = simd_min(p0, p1), high = simd_max(p0, p1)
        guard high.x - low.x > 1e-6, high.y - low.y > 1e-6, profile.height > 1e-6 else { return nil }
        let centre = (low + high) / 2
        let radius = Swift.min(high.x - low.x, high.y - low.y) / 2
        let outline = (0..<48).map { i -> SIMD2<Float> in
            let angle = Float(i) / 48 * 2 * .pi
            return centre + SIMD2(cos(angle), sin(angle)) * radius
        }
        return MeshTouchUp.rebuildPrism(profile, loops: [outline])
    }

    /// A box with rounded vertical edges: the block's footprint (the two axes other than the extrusion
    /// axis) with each corner rounded by `radius`.
    func roundedMesh(radius: Float) -> RenderMesh? {
        guard var profile, kind == .box, radius > 1e-6 else { return nil }
        let n = profile.n
        let a = simd_dot(min, n), b = simd_dot(max, n)
        profile.origin = n * Swift.min(a, b)
        profile.height = abs(b - a)
        let p0 = SIMD2(simd_dot(min, profile.u), simd_dot(min, profile.v))
        let p1 = SIMD2(simd_dot(max, profile.u), simd_dot(max, profile.v))
        let low = simd_min(p0, p1), high = simd_max(p0, p1)
        guard radius < Swift.min(high.x - low.x, high.y - low.y) / 2 else { return nil }
        var outline: [SIMD2<Float>] = []
        let corners: [(SIMD2<Float>, SIMD2<Float>, Float)] = [
            (SIMD2(high.x - radius, low.y + radius), [1, -1], -.pi / 2), (SIMD2(high.x - radius, high.y - radius), [1, 1], 0),
            (SIMD2(low.x + radius, high.y - radius), [-1, 1], .pi / 2), (SIMD2(low.x + radius, low.y + radius), [-1, -1], .pi),
        ]
        for (centre, _, start) in corners {
            for i in 0...8 {
                let angle = start + Float(i) / 8 * .pi / 2
                outline.append(centre + SIMD2(cos(angle), sin(angle)) * radius)
            }
        }
        return MeshTouchUp.rebuildPrism(profile, loops: [outline])
    }
}

/// Every body of the design, seen together and in world axes (x right, y up, z toward the viewer).
struct DesignScene {
    var parts: [DesignPart]

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        (parts.map(\.min).reduce(parts[0].min, simd_min), parts.map(\.max).reduce(parts[0].max, simd_max))
    }
    var extent: SIMD3<Float> { bounds.max - bounds.min }
    var partSizes: [SIMD3<Float>] { parts.map(\.size) }

    /// The parts in millimetres, measured from the middle of the whole design, for the model to read.
    var description: String {
        func mm(_ v: Float) -> String { String(format: "%.1f", v * 1000) }
        let box = bounds
        let middle = (box.min + box.max) / 2
        var lines = [
            "The design is \(mm(extent.x)) mm wide (x), \(mm(extent.y)) mm tall (y, up) and \(mm(extent.z)) mm deep (z).",
            "Parts (size is x by y by z; centre is measured from the middle of the design):",
        ]
        for (i, part) in parts.enumerated() {
            let shape: String
            switch part.kind {
            case .box: shape = "box"
            case .cylinder: shape = "cylinder along \(["x", "y", "z"][part.axis])"
            case .other: shape = "irregular solid (cannot be resized)"
            }
            let c = part.center - middle
            lines.append("P\(i): \(shape), \(mm(part.size.x)) x \(mm(part.size.y)) x \(mm(part.size.z)) mm, centre (\(mm(c.x)), \(mm(c.y)), \(mm(c.z)))")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads every body. Needs at least two so that there is something to relate.
    static func build(from bodies: [(id: UUID, mesh: RenderMesh)]) -> DesignScene? {
        let parts = bodies.compactMap(part(from:))
        return parts.count >= 2 ? DesignScene(parts: parts) : nil
    }

    /// Reads one body: what kind of shape it is, its bounds and its volume.
    static func part(from body: (id: UUID, mesh: RenderMesh)) -> DesignPart? {
        guard !body.mesh.positions.isEmpty else { return nil }
        let box = body.mesh.boundingBox
        let volume = body.mesh.solidProperties?.volume ?? 0
        var part = DesignPart(id: body.id, kind: .other, min: box.min, max: box.max, mesh: body.mesh, volume: volume, axis: -1, profile: nil)

        guard let profile = MeshTouchUp.prismProfile(of: body.mesh), profile.loops.count == 1,
              let axis = (0..<3).first(where: { abs(profile.n[$0]) > 0.999 }) else { return part }
        let loop = profile.loops[0]
        if loop.count == 4, edgesAlign(loop) {
            part.kind = .box
        } else if ShapeAnalysis.analyze(loop).candidates.contains(where: { $0.kind == .circle }) {
            part.kind = .cylinder
        } else {
            return part
        }
        part.axis = axis
        part.profile = profile
        // A box is an extrusion along any of its three axes. Use the thinnest one, so a slab's
        // outline is its big face and the result does not depend on which axis was found first.
        if part.kind == .box {
            let size = box.max - box.min
            let thin = (0..<3).min { size[$0] < size[$1] } ?? axis
            if thin != axis {
                var direction = SIMD3<Float>.zero
                direction[thin] = 1
                if let better = MeshTouchUp.prismProfile(of: body.mesh, axis: direction), better.loops.count == 1 {
                    part.axis = thin
                    part.profile = better
                }
            }
        }
        return part
    }

    /// The four edges run along the plane's own axes, which are the world axes, to within a few degrees.
    private static func edgesAlign(_ loop: [SIMD2<Float>]) -> Bool {
        loop.indices.allSatisfy { i in
            let e = loop[(i + 1) % loop.count] - loop[i]
            let angle = abs(atan2(e.y, e.x)) * 180 / .pi
            let off = angle.truncatingRemainder(dividingBy: 90)
            return Swift.min(off, 90 - off) < 6
        }
    }
}
