import Foundation
import simd

/// What finishing a design changed: replaced meshes, new bodies, colours.
struct FinishResult {
    var meshes: [UUID: RenderMesh] = [:]
    var styles: [UUID: PartStyle] = [:]
    var additions: [(mesh: RenderMesh, style: PartStyle?)] = []
    var notes: [String] = []
    var isEmpty: Bool { meshes.isEmpty && styles.isEmpty && additions.isEmpty }
}

/// Finishes a design without changing any of its dimensions: colours parts by group, rounds the
/// corners of thin flat parts, and braces four posts standing on a slab with rails. None of it
/// depends on what the design is; it depends on the parts' own sizes and how they touch.
enum DesignFinish {
    /// - Parameter groupIDs: the plan's groups as body ids, so they still apply after parts were rebuilt.
    static func finish(_ scene: DesignScene, plan: DesignPlan, groupIDs: [[UUID]], existing: [UUID: PartStyle] = [:]) -> FinishResult {
        var result = FinishResult()
        let indexByID = Dictionary(uniqueKeysWithValues: scene.parts.enumerated().map { ($1.id, $0) })

        // Colours, group by group.
        var coloured: [String: Int] = [:]
        for (group, ids) in zip(plan.groups, groupIDs) {
            guard let style = Palette.style(group.material) else { continue }
            // A part that already has a colour keeps it, so finishing again never repaints.
            for id in ids where existing[id] == nil && indexByID[id] != nil {
                result.styles[id] = style
                coloured[style.name, default: 0] += 1
            }
        }

        // Rounded corners on the thin flat parts the plan names.
        var rounded = 0
        for (group, ids) in zip(plan.groups, groupIDs) where group.softenCorners {
            for id in ids {
                guard let i = indexByID[id], DesignRegularizer.isSlab(scene.parts[i]),
                      let radius = cornerRadius(of: i, in: scene),
                      let mesh = scene.parts[i].roundedMesh(radius: radius) else { continue }
                result.meshes[id] = mesh
                rounded += 1
            }
        }

        // Rails between four posts standing on a slab.
        var railCount = 0
        if plan.addRails != false, let boards = rails(in: scene) {
            let style = result.styles[boards.postID] ?? existing[boards.postID]
            result.additions += boards.meshes.map { ($0, style) }
            railCount = boards.meshes.count
        }

        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if rounded > 0 { result.notes.append("rounded the corners of \(plural(rounded, "part"))") }
        if railCount > 0 { result.notes.append("added \(railCount) rails between the posts") }
        if !coloured.isEmpty {
            let text = coloured.sorted { $0.value > $1.value }.map { "\(plural($0.value, "part")) \($0.key)" }.joined(separator: ", ")
            result.notes.append("coloured \(text)")
        }
        return result
    }

    // MARK: Rounded corners

    /// The largest radius (up to 8% of the part's shorter side) that leaves every part resting on this
    /// one still standing on it: a neighbour tucked into a corner stops that corner being rounded much.
    static func cornerRadius(of index: Int, in scene: DesignScene) -> Float? {
        let part = scene.parts[index]
        let e = part.axis
        let plane = (0..<3).filter { $0 != e }
        let shortSide = Swift.min(part.size[plane[0]], part.size[plane[1]])
        var radius = 0.08 * shortSide
        let tolerance = Swift.max(2e-4, 0.006 * scene.extent[e])

        // Parts resting on either flat face, in the footprint.
        let neighbours = scene.parts.indices.filter { j in
            guard j != index else { return false }
            let other = scene.parts[j]
            let touches = abs(part.min[e] - other.max[e]) < tolerance || abs(part.max[e] - other.min[e]) < tolerance
            let overlaps = plane.allSatisfy { min(part.max[$0], other.max[$0]) - max(part.min[$0], other.min[$0]) > 1e-6 }
            return touches && overlaps
        }.map { scene.parts[$0] }

        func fits(_ r: Float) -> Bool {
            for sa in [Float(-1), 1] { for sb in [Float(-1), 1] {
                for other in neighbours {
                    // How far the neighbour's nearest corner sits in from this part's corner.
                    let ia = sa > 0 ? part.max[plane[0]] - other.max[plane[0]] : other.min[plane[0]] - part.min[plane[0]]
                    let ib = sb > 0 ? part.max[plane[1]] - other.max[plane[1]] : other.min[plane[1]] - part.min[plane[1]]
                    let x = Swift.max(ia, 0), y = Swift.max(ib, 0)
                    guard x < r, y < r else { continue }
                    if (r - x) * (r - x) + (r - y) * (r - y) > r * r { return false }
                }
            } }
            return true
        }
        while radius >= 0.001 {
            if fits(radius) { return radius }
            radius *= 0.7
        }
        return nil
    }

    // MARK: Rails

    /// Four identical posts of the same length, arranged in a rectangle and standing on one slab, with
    /// nothing else on that side of the slab, get four rails joining them just under the slab.
    static func rails(in scene: DesignScene) -> (meshes: [RenderMesh], postID: UUID)? {
        for group in postCandidates(in: scene) {
            if let built = rails(for: group, in: scene) { return built }
        }
        return nil
    }

    private static func postCandidates(in scene: DesignScene) -> [[Int]] {
        var clusters: [[Int]] = []
        for i in scene.parts.indices where scene.parts[i].kind == .box {
            if let c = clusters.firstIndex(where: { cluster in
                let first = scene.parts[cluster[0]]
                return DesignRegularizer.similar(first.size, scene.parts[i].size)
            }) { clusters[c].append(i) } else { clusters.append([i]) }
        }
        return clusters.filter { $0.count == 4 }
    }

    private static func rails(for posts: [Int], in scene: DesignScene) -> (meshes: [RenderMesh], postID: UUID)? {
        let first = scene.parts[posts[0]]
        // The posts stand along their longest dimension.
        let e = (0..<3).max { first.size[$0] < first.size[$1] } ?? 1
        let plane = (0..<3).filter { $0 != e }
        let sizeA = first.size[plane[0]], sizeB = first.size[plane[1]], length = first.size[e]
        // Posts, not blocks: much longer than they are wide.
        guard length >= 1.5 * Swift.max(sizeA, sizeB) else { return nil }

        let tolerance = Swift.max(2e-4, 0.006 * scene.extent[e])
        // The slab they all stand on, and which side of it they are on.
        for slabIndex in scene.parts.indices where !posts.contains(slabIndex) {
            let slab = scene.parts[slabIndex]
            let below = posts.allSatisfy { abs(scene.parts[$0].max[e] - slab.min[e]) < tolerance }
            let above = posts.allSatisfy { abs(scene.parts[$0].min[e] - slab.max[e]) < tolerance }
            guard below || above else { continue }
            // Nothing else may already stand on that side of the slab.
            let crowded = scene.parts.indices.contains { j in
                guard j != slabIndex, !posts.contains(j) else { return false }
                let other = scene.parts[j]
                let touches = below ? abs(other.max[e] - slab.min[e]) < tolerance : abs(other.min[e] - slab.max[e]) < tolerance
                return touches && plane.allSatisfy { min(other.max[$0], slab.max[$0]) - max(other.min[$0], slab.min[$0]) > 1e-6 }
            }
            guard !crowded else { continue }

            // A rectangle of posts: mirrored about its own middle in both directions.
            let centres = posts.map { scene.parts[$0].center }
            let middle = centres.reduce(SIMD3<Float>.zero, +) / 4
            let a = centres.map { abs($0[plane[0]] - middle[plane[0]]) }.reduce(0, +) / 4
            let b = centres.map { abs($0[plane[1]] - middle[plane[1]]) }.reduce(0, +) / 4
            let corners = Set(centres.map { SIMD2<Int>($0[plane[0]] < middle[plane[0]] ? -1 : 1, $0[plane[1]] < middle[plane[1]] ? -1 : 1) })
            guard corners.count == 4,
                  centres.allSatisfy({ abs(abs($0[plane[0]] - middle[plane[0]]) - a) < 0.001 && abs(abs($0[plane[1]] - middle[plane[1]]) - b) < 0.001 }),
                  posts.allSatisfy({ simd_distance(scene.parts[$0].size, first.size) < 0.001 }) else { continue }

            let thickness = Swift.max(0.4 * Swift.min(sizeA, sizeB), 0.002)
            let height = Swift.min(Swift.max(0.18 * length, 0.8 * Swift.max(sizeA, sizeB)), 0.5 * length)
            let spanA = 2 * a - sizeA, spanB = 2 * b - sizeB
            guard spanA > 0.002, spanB > 0.002, height > 0.001 else { continue }
            let inset: Float = 0.0008
            let faceCoordinate = below ? slab.min[e] : slab.max[e]
            let centreE = below ? faceCoordinate - height / 2 : faceCoordinate + height / 2

            func board(alongA: Bool, sign: Float) -> RenderMesh {
                var centre = middle
                var size = SIMD3<Float>.zero
                centre[e] = centreE; size[e] = height
                if alongA {
                    size[plane[0]] = spanA; size[plane[1]] = thickness
                    centre[plane[1]] = middle[plane[1]] + sign * (b + sizeB / 2 - thickness / 2 - inset)
                } else {
                    size[plane[1]] = spanB; size[plane[0]] = thickness
                    centre[plane[0]] = middle[plane[0]] + sign * (a + sizeA / 2 - thickness / 2 - inset)
                }
                return GeometryBuilder.box(width: Double(size.x), height: Double(size.y), depth: Double(size.z)).translated(by: centre)
            }
            let meshes = [board(alongA: true, sign: 1), board(alongA: true, sign: -1), board(alongA: false, sign: 1), board(alongA: false, sign: -1)]
            return (meshes, scene.parts[posts[0]].id)
        }
        return nil
    }
}
