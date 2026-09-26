import Foundation
import simd

/// What the layout pass changed.
struct AssemblyResult {
    var meshes: [UUID: RenderMesh] = [:]
    var notes: [String] = []
}

/// Makes a design look intentional, whatever it is: parts meant to match become identical, the layout
/// becomes symmetric about the design's middle, edges that nearly meet sit flush, and rows of parts
/// are spaced evenly. It works on world-axis blocks and knows nothing about tables or chairs; the
/// plan says which parts are meant to match.
enum DesignRegularizer {
    /// Parts whose dimensions are each within this fraction of each other count as the same kind of part.
    static let sameSize: Float = 0.5
    /// How close (as a fraction of the design's size along an axis) an edge must be to a neighbour's to snap to it.
    static let alignFraction: Float = 0.04
    /// Symmetry is only applied along an axis when at least this fraction of the parts take part in it.
    static let symmetryCoverage: Float = 0.6

    // MARK: Planning without the model

    /// Groups parts of the same kind and similar size, and gives every group the usual rules. Used
    /// when the on-device model is unavailable or its answer cannot be used.
    static func heuristicPlan(for scene: DesignScene) -> DesignPlan {
        var clusters: [[Int]] = []
        for i in scene.parts.indices.filter({ scene.parts[$0].isMovable }).sorted(by: { scene.parts[$0].volume > scene.parts[$1].volume }) {
            let part = scene.parts[i]
            if let c = clusters.firstIndex(where: { cluster in
                let first = scene.parts[cluster[0]]
                return first.kind == part.kind && (first.kind == .box || first.axis == part.axis) && similar(first.size, part.size)
            }) { clusters[c].append(i) } else { clusters.append([i]) }
        }
        let materials = ["oak", "walnut", "grey", "steel", "cherry", "pine", "green", "red"]
        let groups = clusters.enumerated().map { index, members in
            DesignPlan.Group(
                role: members.count > 1 ? "matching parts" : "part", members: members,
                identicalSize: members.count > 1, mirrored: true, alignEdges: true,
                evenlySpaced: members.count >= 3, softenCorners: members.allSatisfy { isSlab(scene.parts[$0]) },
                material: materials[index % materials.count]
            )
        }
        return DesignPlan(kind: "assembly", groups: groups, reason: "similar parts grouped by size")
    }

    static func similar(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        (0..<3).allSatisfy { abs(a[$0] - b[$0]) / Swift.max(a[$0], b[$0], 1e-9) < sameSize }
    }

    /// A thin flat part: its smallest dimension is well under its second smallest.
    static func isSlab(_ part: DesignPart) -> Bool {
        guard part.kind == .box else { return false }
        let s = [part.size.x, part.size.y, part.size.z].sorted()
        return s[0] <= 0.35 * s[1]
    }

    // MARK: Carrying out a plan

    static func align(_ bodies: [(id: UUID, mesh: RenderMesh)], plan: DesignPlan? = nil) -> AssemblyResult {
        guard let scene = DesignScene.build(from: bodies) else { return AssemblyResult() }
        return apply(plan ?? heuristicPlan(for: scene), to: scene)
    }

    static func apply(_ plan: DesignPlan, to scene: DesignScene) -> AssemblyResult {
        var lo = scene.parts.map(\.min), hi = scene.parts.map(\.max)
        let count = scene.parts.count
        let extent = scene.extent
        var resized = Set<Int>(), moved = Set<Int>(), spaced = Set<Int>(), flushed = Set<Int>()
        /// Parts sitting on the centre line along an axis: they stay centred, so they are not nudged flush.
        var onCentre: [Int: Set<Int>] = [:]

        func members(_ group: DesignPlan.Group) -> [Int] {
            group.members.filter { scene.parts.indices.contains($0) && scene.parts[$0].isMovable }
        }
        func centre(_ i: Int) -> SIMD3<Float> { (lo[i] + hi[i]) / 2 }
        func shift(_ i: Int, by d: SIMD3<Float>) { lo[i] += d; hi[i] += d }
        func overlaps(_ i: Int, _ j: Int, skipping axis: Int) -> Bool {
            (0..<3).filter { $0 != axis }.allSatisfy { min(hi[i][$0], hi[j][$0]) - max(lo[i][$0], lo[j][$0]) > -1e-6 }
        }
        /// Whether the face of `i` on `side` (0 low, 1 high) rests against another part.
        func abuts(_ i: Int, axis a: Int, side: Int) -> Bool {
            let tolerance = Swift.max(2e-4, 0.006 * extent[a])
            return (0..<count).contains { j in
                guard j != i, overlaps(i, j, skipping: a) else { return false }
                return side == 0 ? abs(lo[i][a] - hi[j][a]) < tolerance : abs(hi[i][a] - lo[j][a]) < tolerance
            }
        }

        // 1. Parts meant to match get the same dimensions. A face resting on a neighbour stays put.
        for group in plan.groups where group.identicalSize {
            let ids = members(group)
            guard ids.count >= 2 else { continue }
            var target = SIMD3<Float>(repeating: 0)
            for a in 0..<3 { target[a] = median(ids.map { hi[$0][a] - lo[$0][a] }) }
            let axis = scene.parts[ids[0]].axis
            if ids.allSatisfy({ scene.parts[$0].kind == .cylinder && scene.parts[$0].axis == axis }) {
                let others = (0..<3).filter { $0 != axis }
                let diameter = (target[others[0]] + target[others[1]]) / 2
                target[others[0]] = diameter; target[others[1]] = diameter
            }
            for i in ids {
                for a in 0..<3 {
                    let old = hi[i][a] - lo[i][a], new = target[a]
                    guard abs(old - new) > 1e-6 else { continue }
                    let low = abuts(i, axis: a, side: 0), high = abuts(i, axis: a, side: 1)
                    if low && !high { hi[i][a] = lo[i][a] + new }
                    else if high && !low { lo[i][a] = hi[i][a] - new }
                    else { let c = (lo[i][a] + hi[i][a]) / 2; lo[i][a] = c - new / 2; hi[i][a] = c + new / 2 }
                    resized.insert(i)
                }
            }
        }

        // 2. Symmetry about the middle of the design, along each axis that is mostly symmetric.
        for a in 0..<3 {
            let low = lo.map { $0[a] }.min() ?? 0, high = hi.map { $0[a] }.max() ?? 0
            let middle = (low + high) / 2, span = high - low
            guard span > 1e-6 else { continue }
            let dead = 0.08 * span
            let pairTolerance = 0.25 * ((0..<3).map { extent[$0] }.filter { $0 > 1e-6 }.min() ?? span)
            var covered = 0
            var moves: [Int: SIMD3<Float>] = [:]
            for group in plan.groups where group.mirrored {
                let ids = members(group)
                var used = Set<Int>()
                for i in ids where !used.contains(i) {
                    used.insert(i)
                    let ci = centre(i)
                    if abs(ci[a] - middle) < dead {
                        covered += 1
                        moves[i, default: .zero][a] += middle - ci[a]
                        onCentre[a, default: []].insert(i)
                        continue
                    }
                    var image = ci
                    image[a] = 2 * middle - ci[a]
                    let partner = ids.filter { !used.contains($0) && (centre($0)[a] - middle) * (ci[a] - middle) < 0 }
                        .min { simd_distance(centre($0), image) < simd_distance(centre($1), image) }
                    guard let j = partner, simd_distance(centre(j), image) < pairTolerance else { continue }
                    used.insert(j)
                    covered += 2
                    let cj = centre(j)
                    let distance = (abs(ci[a] - middle) + abs(cj[a] - middle)) / 2
                    let sign: Float = ci[a] < middle ? -1 : 1
                    var ni = (ci + cj) / 2, nj = (ci + cj) / 2
                    ni[a] = middle + sign * distance
                    nj[a] = middle - sign * distance
                    moves[i] = ni - ci
                    moves[j] = nj - cj
                }
            }
            guard Float(covered) / Float(count) >= symmetryCoverage else { continue }
            for (i, d) in moves where simd_length(d) > 1e-6 { shift(i, by: d); moved.insert(i) }
        }

        // 3. Rows of three or more are spaced evenly.
        for group in plan.groups where group.evenlySpaced {
            let ids = members(group)
            guard ids.count >= 3 else { continue }
            for a in 0..<3 {
                let sorted = ids.sorted { centre($0)[a] < centre($1)[a] }
                let others = (0..<3).filter { $0 != a }
                let inRow = others.allSatisfy { b in
                    let values = sorted.map { centre($0)[b] }
                    return (values.max() ?? 0) - (values.min() ?? 0) < 0.05 * Swift.max(extent[b], 1e-6)
                }
                guard inRow, let first = sorted.first, let last = sorted.last else { continue }
                let start = centre(first)[a], end = centre(last)[a]
                for (k, i) in sorted.enumerated() {
                    let want = start + (end - start) * Float(k) / Float(sorted.count - 1)
                    let d = want - centre(i)[a]
                    if abs(d) > 1e-6 { var v = SIMD3<Float>.zero; v[a] = d; shift(i, by: v); spaced.insert(i) }
                }
            }
        }

        // 4. An edge within reach of a neighbour's edge sits flush with it (the whole part moves, so its size is kept).
        for group in plan.groups where group.alignEdges {
            for i in members(group) {
                for a in 0..<3 where !(onCentre[a]?.contains(i) ?? false) {
                    let reach = Swift.min(alignFraction * extent[a], 0.25 * (hi[i][a] - lo[i][a]))
                    guard reach > 1e-6 else { continue }
                    // Only bigger parts are anchors: a leg lines up with the top, never the top with a leg.
                    let others = (0..<count).filter { j in
                        j != i && !group.members.contains(j) && scene.parts[j].volume >= scene.parts[i].volume && overlaps(i, j, skipping: a)
                    }
                    let edges = others.flatMap { [lo[$0][a], hi[$0][a]] }
                    // Already lined up with something: leave it, so a part resting on a neighbour is not pushed off.
                    if edges.contains(where: { e in abs(e - lo[i][a]) < 1e-6 || abs(e - hi[i][a]) < 1e-6 }) { continue }
                    var best: Float?
                    for e in edges {
                        for face in [lo[i][a], hi[i][a]] {
                            let d = e - face
                            if abs(d) < reach, abs(d) < abs(best ?? .greatestFiniteMagnitude) { best = d }
                        }
                    }
                    if let d = best { var v = SIMD3<Float>.zero; v[a] = d; shift(i, by: v); flushed.insert(i) }
                }
            }
        }

        var result = AssemblyResult()
        for i in scene.parts.indices where scene.parts[i].isMovable {
            let changed = simd_distance(lo[i], scene.parts[i].min) > 1e-6 || simd_distance(hi[i], scene.parts[i].max) > 1e-6
            guard changed, let mesh = scene.parts[i].rebuilt(lo: lo[i], hi: hi[i]) else { continue }
            result.meshes[scene.parts[i].id] = mesh
        }
        func plural(_ n: Int) -> String { "\(n) part\(n == 1 ? "" : "s")" }
        let changedIDs = Set(result.meshes.keys)
        func tally(_ set: Set<Int>) -> Int { set.filter { changedIDs.contains(scene.parts[$0].id) }.count }
        if tally(resized) > 0 { result.notes.append("made \(plural(tally(resized))) match the rest of their group") }
        if tally(moved) > 0 { result.notes.append("made \(plural(tally(moved))) symmetric about the middle of the design") }
        if tally(spaced) > 0 { result.notes.append("spaced \(plural(tally(spaced))) evenly") }
        if tally(flushed) > 0 { result.notes.append("lined \(plural(tally(flushed))) up flush with a neighbour") }
        return result
    }

    private static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
