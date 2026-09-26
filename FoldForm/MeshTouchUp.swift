import Foundation
import simd

/// What the touch-up pass found (and fixed) on one body.
struct MeshFindings: Equatable {
    /// Single vertices that stuck out of an otherwise flat patch.
    var spikes = 0
    /// Vertices pulled back onto a flat patch they had bumped or dented.
    var patchVertices = 0
    /// Needle-thin triangles improved by flipping the edge they share with a neighbour.
    var flips = 0
    /// Tiny edges of slivers that were merged away.
    var collapses = 0
    /// Zero-area triangles removed.
    var degenerate = 0
    /// Bumps taken out of the body's outline, when it is an extruded outline.
    var outlineBumps = 0
    /// What the outline was snapped to ("rectangle"), for the message.
    var outlineReadings: [String] = []
    /// What the whole body most likely is, if it is a recognisable solid.
    var shapeGuess: String?

    var bumpCount: Int { spikes + patchVertices + outlineBumps }
    var meshFixes: Int { flips + collapses + degenerate }
    var changeCount: Int { bumpCount + meshFixes + outlineReadings.count }
    var isClean: Bool { changeCount == 0 }

    var summary: String {
        "Body findings: \(spikes + patchVertices) bumps, \(flips + collapses) sliver fixes, \(degenerate) degenerate triangles, \(outlineBumps) outline bumps. "
            + (shapeGuess.map { "It looks like a \($0)." } ?? "Its overall shape is not a recognisable solid.")
    }
}

/// An extruded outline recovered from a mesh: every triangle is a cap or a wall and every vertex sits
/// on one of two parallel planes. The loops are in the plane's own coordinates.
struct PrismProfile {
    var origin: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var n: SIMD3<Float>
    var height: Float
    /// The outer outline first, then any holes.
    var loops: [[SIMD2<Float>]]
}

/// Finds and removes odd bumps on a triangle mesh using only triangle geometry: the law of cosines
/// for angles (slivers), face normals for coplanarity, and height above the surrounding plane for
/// spikes and dents. Meshes in this app are flat-shaded, so results are rebuilt flat-shaded.
enum MeshTouchUp {
    /// Faces within this angle (degrees) of a patch's first face belong to that patch.
    static let patchDegrees: Float = 8
    /// An outer face within this angle (degrees) of the others counts as the same flat surface.
    static let coplanarDegrees: Float = 6
    /// A spike stands this far above its surroundings, as a fraction of the ring's edge length.
    static let spikeHeight: ClosedRange<Float> = 0.04...0.5
    /// A triangle with an angle below this (degrees) is a sliver.
    static let sliverDegrees: Float = 12
    /// Edges shorter than this fraction of the body's size may be collapsed when they belong to a sliver.
    static let collapseFraction: Float = 0.004

    // MARK: Welded topology

    struct Edge: Hashable {
        let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    struct Topology {
        var points: [SIMD3<Float>] = []
        var tris: [SIMD3<Int>] = []
        var diagonal: Float = 0

        init(_ mesh: RenderMesh) {
            let box = mesh.boundingBox
            diagonal = simd_length(box.max - box.min)
            let cell = max(diagonal * 1e-5, 1e-7)
            struct Key: Hashable { let x: Int, y: Int, z: Int }
            var lookup: [Key: Int] = [:]
            var ids: [Int] = []
            for p in mesh.positions {
                let key = Key(x: Int((p.x / cell).rounded()), y: Int((p.y / cell).rounded()), z: Int((p.z / cell).rounded()))
                if let existing = lookup[key] { ids.append(existing) } else {
                    lookup[key] = points.count
                    ids.append(points.count)
                    points.append(p)
                }
            }
            for start in stride(from: 0, through: mesh.indices.count - 3, by: 3) {
                let i0 = Int(mesh.indices[start]), i1 = Int(mesh.indices[start + 1]), i2 = Int(mesh.indices[start + 2])
                guard i0 < ids.count, i1 < ids.count, i2 < ids.count else { continue }
                tris.append(SIMD3(ids[i0], ids[i1], ids[i2]))
            }
        }

        static func edges(of t: SIMD3<Int>) -> [Edge] { [Edge(t.x, t.y), Edge(t.y, t.z), Edge(t.z, t.x)] }

        func normal(_ f: Int) -> SIMD3<Float>? { Self.unitNormal(tris[f], points) }

        static func unitNormal(_ t: SIMD3<Int>, _ p: [SIMD3<Float>]) -> SIMD3<Float>? {
            let n = simd_cross(p[t.y] - p[t.x], p[t.z] - p[t.x])
            let length = simd_length(n)
            return length > 1e-14 ? n / length : nil
        }

        func edgeFaces() -> [Edge: [Int]] {
            var map: [Edge: [Int]] = [:]
            for (f, t) in tris.enumerated() { for e in Self.edges(of: t) { map[e, default: []].append(f) } }
            return map
        }

        func vertexFaces() -> [[Int]] {
            var result = [[Int]](repeating: [], count: points.count)
            for (f, t) in tris.enumerated() { for v in [t.x, t.y, t.z] { result[v].append(f) } }
            return result
        }

        /// Smallest interior angle in degrees, from the law of cosines; 0 for a collapsed triangle.
        static func smallestAngle(_ t: SIMD3<Int>, _ p: [SIMD3<Float>]) -> Float {
            let a = simd_distance(p[t.y], p[t.z]), b = simd_distance(p[t.x], p[t.z]), c = simd_distance(p[t.x], p[t.y])
            guard a > 1e-12, b > 1e-12, c > 1e-12 else { return 0 }
            func angle(_ opposite: Float, _ s1: Float, _ s2: Float) -> Float {
                acos(min(max((s1 * s1 + s2 * s2 - opposite * opposite) / (2 * s1 * s2), -1), 1)) * 180 / .pi
            }
            return min(angle(a, b, c), angle(b, a, c), angle(c, a, b))
        }

        func mesh() -> RenderMesh {
            var result = RenderMesh.empty
            for t in tris {
                guard let n = normal(t: t) else { continue }
                let base = UInt32(result.positions.count)
                result.positions += [points[t.x], points[t.y], points[t.z]]
                result.normals += [n, n, n]
                result.indices += [base, base + 1, base + 2]
            }
            return result
        }

        private func normal(t: SIMD3<Int>) -> SIMD3<Float>? { Self.unitNormal(t, points) }
    }

    // MARK: Repair stages

    /// Triangles with a repeated corner or (nearly) no area.
    private static func removeDegenerate(_ t: inout Topology) -> Int {
        let before = t.tris.count
        t.tris = t.tris.filter { tri in
            guard tri.x != tri.y, tri.y != tri.z, tri.x != tri.z else { return false }
            let a = t.points[tri.x], b = t.points[tri.y], c = t.points[tri.z]
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            return area > longest * longest * 1e-4 && area > 1e-14
        }
        return before - t.tris.count
    }

    /// A vertex whose surrounding faces are all coplanar with each other, but which stands slightly
    /// proud of them, is pushed back onto that surface.
    private static func flattenSpikes(_ t: inout Topology) -> Int {
        let edgeFaces = t.edgeFaces(), vertexFaces = t.vertexFaces()
        var moved: [Int: SIMD3<Float>] = [:]
        for v in t.points.indices {
            let faces = Set(vertexFaces[v])
            guard faces.count >= 4 else { continue }
            var ring = Set<Int>()
            var outerNormals: [SIMD3<Float>] = []
            var ringEdges: [Edge] = []
            var closed = true
            for f in faces {
                let tri = t.tris[f]
                let others = [tri.x, tri.y, tri.z].filter { $0 != v }
                guard others.count == 2 else { closed = false; break }
                ring.formUnion(others)
                let edge = Edge(others[0], others[1])
                ringEdges.append(edge)
                let across = (edgeFaces[edge] ?? []).filter { !faces.contains($0) }
                guard across.count == 1, let n = t.normal(across[0]) else { closed = false; break }
                outerNormals.append(n)
            }
            guard closed, ring.count >= 4, let reference = outerNormals.first else { continue }
            guard outerNormals.allSatisfy({ acos(min(max(simd_dot($0, reference), -1), 1)) * 180 / .pi < coplanarDegrees }) else { continue }
            let mean = simd_normalize(outerNormals.reduce(SIMD3<Float>.zero, +))
            guard mean.x.isFinite else { continue }
            let center = ring.reduce(SIMD3<Float>.zero) { $0 + t.points[$1] } / Float(ring.count)
            let height = simd_dot(t.points[v] - center, mean)
            let edgeLength = ringEdges.reduce(Float(0)) { $0 + simd_distance(t.points[$1.a], t.points[$1.b]) } / Float(ringEdges.count)
            guard edgeLength > 1e-9, spikeHeight.contains(abs(height) / edgeLength) else { continue }
            moved[v] = t.points[v] - mean * height
        }
        for (v, p) in moved { t.points[v] = p }
        return moved.count
    }

    /// Groups nearly-flat neighbouring faces into patches and pulls the vertices in the middle of
    /// each patch onto the plane its border defines, which takes out gentle bumps and dents that
    /// span several vertices.
    private static func flattenPatches(_ t: inout Topology) -> Int {
        let edgeFaces = t.edgeFaces(), vertexFaces = t.vertexFaces()
        let normals = t.tris.indices.map { t.normal($0) }
        let limit = cos(patchDegrees * .pi / 180)
        var patchOf = [Int](repeating: -1, count: t.tris.count)
        var patches: [[Int]] = []
        for seed in t.tris.indices where patchOf[seed] < 0 {
            guard let seedNormal = normals[seed] else { continue }
            let id = patches.count
            patchOf[seed] = id
            var members = [seed], stack = [seed]
            while let f = stack.popLast() {
                for edge in Topology.edges(of: t.tris[f]) {
                    for g in edgeFaces[edge] ?? [] where patchOf[g] < 0 {
                        guard let gn = normals[g], simd_dot(gn, seedNormal) > limit else { continue }
                        patchOf[g] = id
                        members.append(g)
                        stack.append(g)
                    }
                }
            }
            patches.append(members)
        }

        var updated = t.points
        var moved = 0
        for (id, members) in patches.enumerated() where members.count >= 4 {
            var verts = Set<Int>()
            for f in members { verts.formUnion([t.tris[f].x, t.tris[f].y, t.tris[f].z]) }
            let interior = verts.filter { v in vertexFaces[v].allSatisfy { patchOf[$0] == id } }
            let border = verts.subtracting(interior)
            guard !interior.isEmpty, border.count >= 3 else { continue }
            var weighted = SIMD3<Float>.zero
            var edgeTotal: Float = 0
            for f in members {
                let tri = t.tris[f]
                if [tri.x, tri.y, tri.z].contains(where: border.contains) {
                    weighted += simd_cross(t.points[tri.y] - t.points[tri.x], t.points[tri.z] - t.points[tri.x])
                }
                edgeTotal += simd_distance(t.points[tri.x], t.points[tri.y])
            }
            guard simd_length(weighted) > 1e-14 else { continue }
            let normal = simd_normalize(weighted)
            let origin = border.reduce(SIMD3<Float>.zero) { $0 + t.points[$1] } / Float(border.count)
            let edgeLength = edgeTotal / Float(members.count)
            for v in interior {
                let offset = simd_dot(t.points[v] - origin, normal)
                guard abs(offset) > edgeLength * 1e-3, abs(offset) < edgeLength * 0.4 else { continue }
                updated[v] = t.points[v] - normal * offset
                moved += 1
            }
        }
        t.points = updated
        return moved
    }

    /// Delaunay-style improvement: where two coplanar triangles form a convex quad, use the diagonal
    /// that gives the fatter triangles. The surface does not move; only the triangulation changes.
    private static func flipSlivers(_ t: inout Topology) -> Int {
        var total = 0
        for _ in 0..<12 {
            let edgeFaces = t.edgeFaces()
            var touched = Set<Int>()
            var flips = 0
            for (edge, faces) in edgeFaces where faces.count == 2 {
                let f = faces[0], g = faces[1]
                guard !touched.contains(f), !touched.contains(g),
                      let nf = t.normal(f), let ng = t.normal(g), simd_dot(nf, ng) > 0.9998 else { continue }
                let tf = t.tris[f], tg = t.tris[g]
                let fv = [tf.x, tf.y, tf.z], gv = [tg.x, tg.y, tg.z]
                // Directed edge a->b in f, with c opposite; g must run b->a with d opposite.
                guard let i = (0..<3).first(where: { Edge(fv[$0], fv[($0 + 1) % 3]) == edge }) else { continue }
                let a = fv[i], b = fv[(i + 1) % 3], c = fv[(i + 2) % 3]
                guard let j = (0..<3).first(where: { gv[$0] == b && gv[($0 + 1) % 3] == a }) else { continue }
                let d = gv[(j + 2) % 3]
                let first = SIMD3(a, d, c), second = SIMD3(d, b, c)
                guard let n1 = Topology.unitNormal(first, t.points), let n2 = Topology.unitNormal(second, t.points),
                      simd_dot(n1, nf) > 0.99, simd_dot(n2, nf) > 0.99 else { continue }
                let before = min(Topology.smallestAngle(tf, t.points), Topology.smallestAngle(tg, t.points))
                let after = min(Topology.smallestAngle(first, t.points), Topology.smallestAngle(second, t.points))
                guard before < sliverDegrees, after > before + 2 else { continue }
                t.tris[f] = first
                t.tris[g] = second
                touched.insert(f); touched.insert(g)
                flips += 1
            }
            total += flips
            if flips == 0 { break }
        }
        return total
    }

    /// Slivers with a tiny edge: merge the two ends into their midpoint.
    private static func collapseSlivers(_ t: inout Topology) -> Int {
        let limit = t.diagonal * collapseFraction
        var remap = Array(t.points.indices)
        func root(_ v: Int) -> Int {
            var r = v
            while remap[r] != r { r = remap[r] }
            return r
        }
        var collapses = 0
        for tri in t.tris where Topology.smallestAngle(tri, t.points) < 5 {
            for e in Topology.edges(of: tri) where simd_distance(t.points[e.a], t.points[e.b]) < limit {
                let a = root(e.a), b = root(e.b)
                guard a != b else { continue }
                t.points[a] = (t.points[a] + t.points[b]) / 2
                remap[b] = a
                collapses += 1
            }
        }
        guard collapses > 0 else { return 0 }
        t.tris = t.tris.map { SIMD3(root($0.x), root($0.y), root($0.z)) }
        return collapses
    }

    // MARK: Entry points

    /// Runs every repair stage. Returns the repaired mesh (or the original if nothing changed) and
    /// what was done.
    static func repair(_ mesh: RenderMesh) -> (mesh: RenderMesh, findings: MeshFindings) {
        var findings = MeshFindings(shapeGuess: shapeGuess(mesh))
        guard mesh.indices.count >= 3 else { return (mesh, findings) }
        var t = Topology(mesh)
        findings.degenerate += removeDegenerate(&t)
        findings.spikes = flattenSpikes(&t)
        findings.patchVertices = flattenPatches(&t)
        findings.flips = flipSlivers(&t)
        findings.collapses = collapseSlivers(&t)
        findings.degenerate += removeDegenerate(&t)
        guard findings.meshFixes + findings.spikes + findings.patchVertices > 0 else { return (mesh, findings) }
        return (t.mesh(), findings)
    }

    static func analyze(_ mesh: RenderMesh) -> MeshFindings { repair(mesh).findings }

    static func smoothed(_ mesh: RenderMesh) -> RenderMesh { repair(mesh).mesh }

    /// Box or cylinder, from how much of its bounding box the solid fills (1 for a box, pi/4 for a
    /// cylinder standing along an axis).
    static func shapeGuess(_ mesh: RenderMesh) -> String? {
        guard let properties = mesh.solidProperties else { return nil }
        let box = mesh.boundingBox
        let size = box.max - box.min
        let boxVolume = size.x * size.y * size.z
        guard boxVolume > 1e-12 else { return nil }
        let fill = properties.volume / boxVolume
        if fill > 0.96 { return "box" }
        if abs(fill - .pi / 4) < 0.05 { return "cylinder" }
        return nil
    }

    // MARK: Extruded outlines

    /// The outline (and holes) of a body that is a straight extrusion, or nil if it is not one.
    static func prismProfile(of mesh: RenderMesh) -> PrismProfile? {
        guard mesh.indices.count >= 24 else { return nil }
        let t = Topology(mesh)
        var axes: [(n: SIMD3<Float>, area: Float)] = []
        for f in t.tris.indices {
            guard let n = t.normal(f) else { continue }
            let tri = t.tris[f]
            let area = simd_length(simd_cross(t.points[tri.y] - t.points[tri.x], t.points[tri.z] - t.points[tri.x])) / 2
            if let i = axes.firstIndex(where: { abs(simd_dot($0.n, n)) > 0.9995 }) { axes[i].area += area } else { axes.append((n, area)) }
        }
        // Every distinct face direction is a candidate: the caps of an extruded outline with slanted
        // sides are never the biggest faces, and a wrong axis is rejected at the first mismatching face.
        for axis in axes.sorted(by: { $0.area > $1.area }) {
            if let profile = profile(of: t, axis: axis.n) { return profile }
        }
        return nil
    }

    /// The outline of a body that is an extrusion along exactly `axis` (either direction), in the same
    /// plane coordinates as every other body given the same axis.
    static func prismProfile(of mesh: RenderMesh, axis: SIMD3<Float>) -> PrismProfile? {
        guard mesh.indices.count >= 24 else { return nil }
        return profile(of: Topology(mesh), axis: axis)
    }

    /// The directions a body could be an extrusion along, biggest faces first.
    static func candidateAxes(of mesh: RenderMesh) -> [SIMD3<Float>] {
        let t = Topology(mesh)
        var axes: [(n: SIMD3<Float>, area: Float)] = []
        for f in t.tris.indices {
            guard let n = t.normal(f) else { continue }
            let tri = t.tris[f]
            let area = simd_length(simd_cross(t.points[tri.y] - t.points[tri.x], t.points[tri.z] - t.points[tri.x])) / 2
            if let i = axes.firstIndex(where: { abs(simd_dot($0.n, n)) > 0.9995 }) { axes[i].area += area } else { axes.append((n, area)) }
        }
        return axes.sorted { $0.area > $1.area }.prefix(3).map(\.n)
    }

    private static func profile(of t: Topology, axis: SIMD3<Float>) -> PrismProfile? {
        let n = simd_normalize(axis)
        for f in t.tris.indices {
            guard let fn = t.normal(f) else { return nil }
            let d = abs(simd_dot(fn, n))
            guard d > 0.9995 || d < 0.02 else { return nil }
        }
        let heights = t.points.map { simd_dot($0, n) }
        guard let lo = heights.min(), let hi = heights.max(), hi - lo > 1e-6 else { return nil }
        let tolerance = max(t.diagonal * 1e-4, 1e-7)
        guard heights.allSatisfy({ abs($0 - lo) < tolerance || abs($0 - hi) < tolerance }) else { return nil }

        // Directed boundary of the bottom cap; the cap faces away from the extrusion direction.
        var directed = Set<SIMD2<Int>>()
        var hasTop = false
        for f in t.tris.indices {
            guard let fn = t.normal(f) else { continue }
            let d = simd_dot(fn, n)
            if d > 0.9995 { hasTop = true }
            guard d < -0.9995 else { continue }
            let tri = t.tris[f]
            for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] { directed.insert(SIMD2(a, b)) }
        }
        guard hasTop, !directed.isEmpty else { return nil }
        var next: [Int: Int] = [:]
        for e in directed where !directed.contains(SIMD2(e.y, e.x)) {
            guard next[e.x] == nil else { return nil }
            next[e.x] = e.y
        }
        guard !next.isEmpty else { return nil }

        let helper: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(n, helper))
        let v = simd_cross(n, u)
        var visited = Set<Int>()
        var loops: [[SIMD2<Float>]] = []
        for start in next.keys.sorted() where !visited.contains(start) {
            var loop: [SIMD2<Float>] = []
            var current = start
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(SIMD2(simd_dot(t.points[current], u), simd_dot(t.points[current], v)))
                guard let following = next[current] else { return nil }
                current = following
            }
            guard current == start, loop.count >= 3 else { return nil }
            loops.append(loop)
        }
        func area(_ loop: [SIMD2<Float>]) -> Float {
            abs(loop.indices.reduce(Float(0)) { $0 + (loop[$1].x * loop[($1 + 1) % loop.count].y - loop[($1 + 1) % loop.count].x * loop[$1].y) } / 2)
        }
        loops.sort { area($0) > area($1) }
        return PrismProfile(origin: n * lo, u: u, v: v, n: n, height: hi - lo, loops: loops)
    }

    /// The prism for `profile`'s plane and height with new loops (outer first).
    static func rebuildPrism(_ profile: PrismProfile, loops: [[SIMD2<Float>]]) -> RenderMesh? {
        guard let outer = loops.first else { return nil }
        func widen(_ loop: [SIMD2<Float>]) -> [SIMD2<Double>] { loop.map { SIMD2<Double>(Double($0.x), Double($0.y)) } }
        guard let local = try? GeometryBuilder.prism(
            outer: widen(outer), holes: loops.dropFirst().map(widen), height: Double(profile.height), centered: false
        ) else { return nil }
        return local.placed(origin: profile.origin, u: profile.u, v: profile.v, n: profile.n)
    }
}
