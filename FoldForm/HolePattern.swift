import Foundation
import simd

/// Small 2D helpers shared by the hole pattern and the shape analysis.
enum PlaneMath {
    static func rotate(_ p: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
    }

    /// Which way a roughly rectangular outline is turned, from its edge directions modulo 90 degrees.
    static func edgeAngle(of loop: [SIMD2<Float>]) -> Float {
        guard loop.count == 4 else { return 0 }
        var sine: Float = 0, cosine: Float = 0
        for i in loop.indices {
            let e = loop[(i + 1) % 4] - loop[i]
            let a = atan2(e.y, e.x) * 4
            sine += sin(a); cosine += cos(a)
        }
        return atan2(sine, cosine) / 4
    }
}

/// Mirror symmetry about the middle of a rectangle, in that rectangle's own frame (origin at its
/// centre, axes along its edges).
enum Symmetry {
    /// A gap to an edge under this fraction of the width closes up so the part sits flush.
    static let flushFraction: Float = 0.06

    /// Makes `points` symmetric about both axes. Each point is paired with its nearest mirror image;
    /// a pair shares one distance from the axis and one position along it. A point on an axis is put
    /// exactly on it. Points with no partner are left alone.
    static func mirror(_ points: inout [SIMD2<Float>], sizes: [SIMD2<Float>], half: SIMD2<Float>, flush: Bool) {
        for axis in 0..<2 {
            let across = axis, along = 1 - axis
            let reach = half[across]
            let dead = reach * 0.04
            var used = Set<Int>()
            for i in points.indices where !used.contains(i) {
                used.insert(i)
                if abs(points[i][across]) < dead { points[i][across] = 0; continue }
                var mirrored = points[i]
                mirrored[across] = -mirrored[across]
                let partner = points.indices.filter { !used.contains($0) && points[$0][across] * points[i][across] < 0 }
                    .min { simd_distance(points[$0], mirrored) < simd_distance(points[$1], mirrored) }
                guard let j = partner, simd_distance(points[j], mirrored) < 0.5 * min(half.x, half.y) * 2 else { continue }
                used.insert(j)
                let distance = (abs(points[i][across]) + abs(points[j][across])) / 2
                let position = (points[i][along] + points[j][along]) / 2
                let sign: Float = points[i][across] < 0 ? -1 : 1
                points[i][across] = sign * distance; points[j][across] = -sign * distance
                points[i][along] = position; points[j][along] = position
            }
        }
        if flush {
            // Snap the mirrored groups together so symmetry survives: every point moves by the same rule.
            for i in points.indices { snapFlush(&points[i], size: sizes[i], half: half) }
        }
    }

    /// A gap to an edge under a small fraction of the width closes up so the part sits flush.
    static func snapFlush(_ point: inout SIMD2<Float>, size: SIMD2<Float>, half: SIMD2<Float>) {
        for axis in 0..<2 {
            let reach = half[axis]
            let flush = reach - size[axis] / 2
            guard abs(point[axis]) > reach * 0.04 else { continue }
            if abs(abs(point[axis]) - flush) < 2 * reach * flushFraction {
                point[axis] = (point[axis] < 0 ? -1 : 1) * flush
            }
        }
    }

    static func isFlush(_ center: SIMD2<Float>, size: SIMD2<Float>, half: SIMD2<Float>) -> Bool {
        (0..<2).contains { abs(abs(center[$0]) + size[$0] / 2 - half[$0]) < 1e-5 }
    }
}

/// Holes in one plate: circles of nearly the same size become identical and are mirrored about the
/// plate's centre, like the mounting holes of a bracket.
enum HolePattern {
    static func regularise(_ loops: [[SIMD2<Float>]]) -> (loops: [[SIMD2<Float>]], changed: Bool) {
        guard loops.count >= 3 else { return (loops, false) }
        let outer = loops[0]
        let theta = PlaneMath.edgeAngle(of: outer)
        let rotated = outer.map { PlaneMath.rotate($0, by: -theta) }
        let low = rotated.reduce(rotated[0], simd_min), high = rotated.reduce(rotated[0], simd_max)
        let offset = (low + high) / 2, half = (high - low) / 2
        guard half.x > 1e-6, half.y > 1e-6 else { return (loops, false) }

        var holes: [(center: SIMD2<Float>, radius: Float)] = []
        for loop in loops.dropFirst() {
            guard let circle = ShapeAnalysis.analyze(loop).candidates.first(where: { $0.kind == .circle })?.circle else { return (loops, false) }
            holes.append((PlaneMath.rotate(circle.center, by: -theta) - offset, circle.radius))
        }
        let radii = holes.map(\.radius).sorted()
        let radius = radii[radii.count / 2]
        guard radii.allSatisfy({ abs($0 - radius) / radius < 0.4 }) else { return (loops, false) }
        var centers = holes.map(\.center)
        Symmetry.mirror(&centers, sizes: holes.map { _ in SIMD2(repeating: radius * 2) }, half: half, flush: false)

        var result = [outer]
        var changed = false
        for (index, hole) in holes.enumerated() {
            let center = PlaneMath.rotate(centers[index] + offset, by: theta)
            result.append((0..<48).map { i -> SIMD2<Float> in
                let a = Float(i) / 48 * 2 * .pi
                return center + SIMD2(cos(a), sin(a)) * radius
            })
            if abs(hole.radius - radius) > 1e-6 || simd_distance(centers[index], hole.center) > 1e-6 { changed = true }
        }
        return changed ? (result, true) : (loops, false)
    }
}
