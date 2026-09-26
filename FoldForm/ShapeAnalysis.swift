import Foundation
import simd

/// What a hand-drawn outline was most likely meant to be.
enum IntendedShape: String, Equatable {
    case rightTriangle = "right triangle"
    case rightIsoscelesTriangle = "right isosceles triangle"
    case equilateralTriangle = "equilateral triangle"
    case isoscelesTriangle = "isosceles triangle"
    case square
    case rectangle
    case regularPolygon = "regular polygon"
    case circle

    /// More specific readings win over general ones when both fit.
    var specificity: Int {
        switch self {
        case .rightIsoscelesTriangle, .equilateralTriangle, .square, .regularPolygon, .circle: 3
        case .rightTriangle, .isoscelesTriangle, .rectangle: 2
        }
    }
}

/// One way the drawn outline could be tidied up, with the theorem that supports it.
struct ShapeCandidate: Equatable {
    var kind: IntendedShape
    /// The tidied closed outline. For a circle these are the drawn points' best-fit circle samples.
    var points: [SIMD2<Float>]
    var circle: (center: SIMD2<Float>, radius: Float)?
    /// Mean distance the corners move, as a fraction of the outline's size.
    var error: Float
    var note: String

    static func == (l: ShapeCandidate, r: ShapeCandidate) -> Bool {
        l.kind == r.kind && l.points == r.points && l.error == r.error
    }
}

/// Everything found out about one closed outline.
struct LoopAnalysis {
    var raw: [SIMD2<Float>]
    /// The outline with bumps and wobble removed, still the user's own corners.
    var cleaned: [SIMD2<Float>]
    var candidates: [ShapeCandidate]

    var bumpsRemoved: Int { max(raw.count - cleaned.count, 0) }

    /// The reading geometry alone would choose: the most specific candidate that fits well.
    var bestCandidate: ShapeCandidate? {
        candidates.filter { $0.error < ShapeAnalysis.maxCandidateError }
            .max { l, r in
                l.kind.specificity != r.kind.specificity ? l.kind.specificity < r.kind.specificity : l.error > r.error
            }
    }

    /// Side lengths and angles, in plain words, for the local model to read.
    var summary: String {
        let sides = ShapeAnalysis.sideLengths(cleaned).map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")
        let angles = ShapeAnalysis.interiorAngles(cleaned).map { String(format: "%.0f", $0) }.joined(separator: ", ")
        return "Hand-drawn closed outline: \(raw.count) points drawn, \(cleaned.count) corners after removing \(bumpsRemoved) bump points. "
            + "Side lengths (mm): \(sides). Interior angles (degrees): \(angles)."
    }
}

/// Geometry that turns a wobbly hand-drawn outline into the shape it was aiming for. Everything
/// here is deterministic; the on-device model only chooses between the candidates it produces.
enum ShapeAnalysis {
    /// A candidate that moves the corners more than this is not a believable reading.
    static let maxCandidateError: Float = 0.06
    /// Bump tolerance as a fraction of the outline's size.
    static let bumpTolerance: Float = 0.035
    /// Corners turning less than this (degrees) are just the edge continuing straight.
    static let straightTurnDegrees: Float = 7

    // MARK: Measurements

    static func sideLengths(_ p: [SIMD2<Float>]) -> [Float] {
        p.indices.map { simd_distance(p[$0], p[($0 + 1) % p.count]) }
    }

    /// Interior angle at every corner in degrees, by the law of cosines on the two sides meeting there.
    static func interiorAngles(_ p: [SIMD2<Float>]) -> [Float] {
        p.indices.map { i in
            let prev = p[(i + p.count - 1) % p.count], cur = p[i], next = p[(i + 1) % p.count]
            let a = simd_distance(cur, prev), b = simd_distance(cur, next), c = simd_distance(prev, next)
            guard a > 1e-9, b > 1e-9 else { return 0 }
            let cosine = min(max((a * a + b * b - c * c) / (2 * a * b), -1), 1)
            return acos(cosine) * 180 / .pi
        }
    }

    static func size(of p: [SIMD2<Float>]) -> Float {
        guard let first = p.first else { return 0 }
        var lo = first, hi = first
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        return simd_length(hi - lo)
    }

    private static func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> {
        p.reduce(SIMD2<Float>.zero, +) / Float(max(p.count, 1))
    }

    private static func perpendicular(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(-v.y, v.x) }

    private static func normalized(_ v: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(v)
        return length > 1e-12 ? v / length : .zero
    }

    /// Mean distance from each original corner to the nearest corner of the tidied outline.
    private static func movement(from old: [SIMD2<Float>], to new: [SIMD2<Float>]) -> Float {
        let scale = max(size(of: old), 1e-9)
        let total = old.reduce(Float(0)) { sum, p in sum + (new.map { simd_distance($0, p) }.min() ?? 0) }
        return total / Float(max(old.count, 1)) / scale
    }

    // MARK: Bump removal

    /// Removes bumps: points that only wobble away from a straighter path (Ramer-Douglas-Peucker on
    /// the closed outline), then corners that turn so little they are really the edge continuing.
    static func simplify(_ loop: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard loop.count > 3 else { return loop }
        let tolerance = size(of: loop) * bumpTolerance
        let far = loop.indices.max { simd_distance(loop[$0], loop[0]) < simd_distance(loop[$1], loop[0]) } ?? 0
        guard far != 0 else { return loop }
        var keep = Set<Int>([0, far])
        rdp(loop, from: 0, to: far, tolerance: tolerance, keep: &keep)
        rdp(loop, from: far, to: loop.count, tolerance: tolerance, keep: &keep)
        var result = keep.sorted().map { loop[$0] }
        guard result.count >= 3 else { return loop }

        var changed = true
        while changed, result.count > 3 {
            changed = false
            for i in result.indices {
                let prev = result[(i + result.count - 1) % result.count], cur = result[i], next = result[(i + 1) % result.count]
                let inA = normalized(cur - prev), outA = normalized(next - cur)
                let turn = acos(min(max(simd_dot(inA, outA), -1), 1)) * 180 / .pi
                if turn < straightTurnDegrees {
                    result.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    private static func rdp(_ p: [SIMD2<Float>], from start: Int, to end: Int, tolerance: Float, keep: inout Set<Int>) {
        let a = p[start], b = p[end % p.count]
        var worst = -1
        var worstDistance = tolerance
        for i in (start + 1)..<end {
            let d = distance(p[i % p.count], toSegment: a, b)
            if d > worstDistance { worstDistance = d; worst = i }
        }
        guard worst >= 0 else { return }
        keep.insert(worst % p.count)
        rdp(p, from: start, to: worst, tolerance: tolerance, keep: &keep)
        rdp(p, from: worst, to: end, tolerance: tolerance, keep: &keep)
    }

    private static func distance(_ p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 1e-18 else { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_distance(p, a + ab * t)
    }

    // MARK: Interpretation

    /// `quadTolerance` is how far (degrees) from 90 a four-cornered outline's angles may be and still
    /// read as a rectangle; bodies use a wider one than hand-drawn sketch lines.
    static func analyze(_ raw: [SIMD2<Float>], quadTolerance: Float = 14) -> LoopAnalysis {
        var candidates: [ShapeCandidate] = []
        let circle = circleFit(raw)
        if let circle { candidates.append(circle) }
        let cleaned = circle == nil ? simplify(raw) : raw
        switch circle == nil ? cleaned.count : 0 {
        case 3: candidates += triangleCandidates(cleaned)
        case 4: candidates += quadCandidates(cleaned, tolerance: quadTolerance)
        case 5...: if let polygon = regularPolygon(cleaned) { candidates.append(polygon) }
        default: break
        }
        candidates.sort { $0.error < $1.error }
        return LoopAnalysis(raw: raw, cleaned: cleaned, candidates: candidates)
    }

    /// A many-cornered convex loop whose points all sit at one distance from the middle is a circle.
    private static func circleFit(_ p: [SIMD2<Float>]) -> ShapeCandidate? {
        guard p.count >= 10 else { return nil }
        let center = centroid(p)
        let radii = p.map { simd_distance($0, center) }
        let mean = radii.reduce(0, +) / Float(radii.count)
        guard mean > 1e-6 else { return nil }
        let variation = sqrt(radii.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(radii.count)) / mean
        // Going once round: the signed turns add up to one full revolution, wobble and all.
        var revolution: Float = 0
        for i in p.indices {
            let a = p[(i + 1) % p.count] - p[i], b = p[(i + 2) % p.count] - p[(i + 1) % p.count]
            revolution += atan2(a.x * b.y - a.y * b.x, simd_dot(a, b))
        }
        guard variation < 0.07, abs(abs(revolution) - 2 * .pi) < 0.35 else { return nil }
        let samples = (0..<48).map { i -> SIMD2<Float> in
            let angle = Float(i) / 48 * 2 * .pi
            return center + SIMD2(cos(angle), sin(angle)) * mean
        }
        return ShapeCandidate(
            kind: .circle, points: samples, circle: (center, mean), error: variation,
            note: "every point is within \(Int(variation * 100 + 0.5))% of one radius from the centre"
        )
    }

    private static func triangleCandidates(_ p: [SIMD2<Float>]) -> [ShapeCandidate] {
        let sides = (0..<3).map { simd_distance(p[($0 + 1) % 3], p[($0 + 2) % 3]) }   // side i faces corner i
        guard sides.allSatisfy({ $0 > 1e-9 }) else { return [] }
        var result: [ShapeCandidate] = []
        let longest = sides.indices.max { sides[$0] < sides[$1] }!
        let shortest = sides.indices.min { sides[$0] < sides[$1] }!

        // Pythagoras' converse: a^2 + b^2 = c^2 means the corner facing c is a right angle.
        let c = sides[longest]
        let legs = (0..<3).filter { $0 != longest }
        let residual = abs(c * c - (sides[legs[0]] * sides[legs[0]] + sides[legs[1]] * sides[legs[1]])) / (c * c)
        if residual < 0.10 {
            let corner = p[longest]
            let e1 = p[(longest + 1) % 3] - corner, e2 = p[(longest + 2) % 3] - corner
            let u = normalized(e1)
            var w = perpendicular(u)
            if simd_dot(w, e2) < 0 { w = -w }
            var l1 = simd_length(e1), l2 = simd_length(e2)
            var kind = IntendedShape.rightTriangle
            if abs(l1 - l2) / max(l1, l2) < 0.10 { l1 = (l1 + l2) / 2; l2 = l1; kind = .rightIsoscelesTriangle }
            let points = [corner, corner + u * l1, corner + w * l2]
            result.append(ShapeCandidate(
                kind: kind, points: points, circle: nil, error: movement(from: p, to: points),
                note: "a² + b² = c² to within \(Int(residual * 100 + 0.5))%, so the corner opposite the longest side is 90°"
            ))
        }

        // Equal sides: the angles follow (isosceles base angles, equilateral 60° each).
        let spread = (sides[longest] - sides[shortest]) / sides[longest]
        if spread < 0.10 {
            let center = centroid(p)
            let side = sides.reduce(0, +) / 3
            let start = p[0] - center
            let angle = atan2(start.y, start.x)
            let winding: Float = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x) > 0 ? 1 : -1
            let points = (0..<3).map { i -> SIMD2<Float> in
                let a = angle + winding * Float(i) * 2 * .pi / 3
                return center + SIMD2(cos(a), sin(a)) * (side / sqrt(3))
            }
            result.append(ShapeCandidate(
                kind: .equilateralTriangle, points: points, circle: nil, error: movement(from: p, to: points),
                note: "all three sides are within \(Int(spread * 100 + 0.5))% of equal, so every angle is 60°"
            ))
        } else if let apexIndex = isoscelesApex(sides) {
            let apex = p[apexIndex], b1 = p[(apexIndex + 1) % 3], b2 = p[(apexIndex + 2) % 3]
            let mid = (b1 + b2) / 2
            let base = normalized(b2 - b1)
            var up = perpendicular(base)
            if simd_dot(up, apex - mid) < 0 { up = -up }
            let height = abs(simd_dot(apex - mid, up))
            let points = [mid + up * height, b1, b2]
            let ordered = apexIndex == 0 ? points : rotate(points, to: apexIndex)
            result.append(ShapeCandidate(
                kind: .isoscelesTriangle, points: ordered, circle: nil, error: movement(from: p, to: ordered),
                note: "two sides are equal, so the base angles match and the apex sits over the base's midpoint"
            ))
        }
        return result
    }

    /// The corner between the two nearly equal sides, if exactly two match.
    private static func isoscelesApex(_ s: [Float]) -> Int? {
        for i in 0..<3 {
            let a = s[(i + 1) % 3], b = s[(i + 2) % 3]
            if abs(a - b) / max(a, b) < 0.08 { return i }
        }
        return nil
    }

    /// `points` has the apex first; put it at `index` so the outline order matches the drawn one.
    private static func rotate(_ points: [SIMD2<Float>], to index: Int) -> [SIMD2<Float>] {
        var result = points
        for i in 0..<3 { result[(index + i) % 3] = points[i] }
        return result
    }

    private static func quadCandidates(_ p: [SIMD2<Float>], tolerance: Float) -> [ShapeCandidate] {
        let angles = interiorAngles(p)
        guard angles.allSatisfy({ abs($0 - 90) < tolerance }) else { return [] }
        // Average the four edge directions modulo 90° to find how the rectangle is turned.
        var sine: Float = 0, cosine: Float = 0
        for i in p.indices {
            let e = p[(i + 1) % 4] - p[i]
            let a = atan2(e.y, e.x) * 4
            sine += sin(a); cosine += cos(a)
        }
        var theta = atan2(sine, cosine) / 4
        // A rectangle drawn a few degrees off the axes was meant to sit square to them.
        let quarter = Float.pi / 2
        let nearest = (theta / quarter).rounded() * quarter
        if abs(theta - nearest) < 6 * .pi / 180 { theta = nearest }
        let c = cos(-theta), s = sin(-theta)
        func toLocal(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(v.x * c - v.y * s, v.x * s + v.y * c) }
        func toWorld(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(v.x * c + v.y * s, -v.x * s + v.y * c) }
        let local = p.map(toLocal)
        let lo = local.reduce(local[0], simd_min), hi = local.reduce(local[0], simd_max)
        let width = hi.x - lo.x, height = hi.y - lo.y
        guard width > 1e-9, height > 1e-9 else { return [] }
        let worst = angles.map { abs($0 - 90) }.max() ?? 0
        var result: [ShapeCandidate] = []

        func corners(_ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> [SIMD2<Float>] {
            let box = [SIMD2(lo.x, lo.y), SIMD2(hi.x, lo.y), SIMD2(hi.x, hi.y), SIMD2(lo.x, hi.y)].map(toWorld)
            // Keep the drawn corner order and winding.
            let start = box.indices.min { simd_distance(box[$0], p[0]) < simd_distance(box[$1], p[0]) }!
            var ordered = (0..<4).map { box[(start + $0) % 4] }
            if simd_distance(ordered[1], p[1]) > simd_distance(ordered[3], p[1]) { ordered = [ordered[0], ordered[3], ordered[2], ordered[1]] }
            return ordered
        }
        let rectangle = corners(lo, hi)
        result.append(ShapeCandidate(
            kind: .rectangle, points: rectangle, circle: nil, error: movement(from: p, to: rectangle),
            note: "all four angles are within \(Int(worst + 0.5))° of 90°, so the opposite sides are parallel"
        ))
        if abs(width - height) / max(width, height) < 0.10 {
            let side = (width + height) / 2
            let mid = (lo + hi) / 2
            let half = SIMD2<Float>(repeating: side / 2)
            let square = corners(mid - half, mid + half)
            result.append(ShapeCandidate(
                kind: .square, points: square, circle: nil, error: movement(from: p, to: square),
                note: "a rectangle whose sides differ by under 10%"
            ))
        }
        return result
    }

    private static func regularPolygon(_ p: [SIMD2<Float>]) -> ShapeCandidate? {
        let n = p.count
        let sides = sideLengths(p)
        let mean = sides.reduce(0, +) / Float(n)
        guard mean > 1e-9 else { return nil }
        let variation = sqrt(sides.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(n)) / mean
        let expected = Float(n - 2) * 180 / Float(n)
        let angles = interiorAngles(p)
        guard variation < 0.12, angles.allSatisfy({ abs($0 - expected) < expected * 0.15 }) else { return nil }
        let center = centroid(p)
        let radius = p.map { simd_distance($0, center) }.reduce(0, +) / Float(n)
        let first = p[0] - center
        let start = atan2(first.y, first.x)
        let winding: Float = (p[1].x - p[0].x) * (p[2].y - p[1].y) - (p[1].y - p[0].y) * (p[2].x - p[1].x) > 0 ? 1 : -1
        let points = (0..<n).map { i -> SIMD2<Float> in
            let a = start + winding * Float(i) * 2 * .pi / Float(n)
            return center + SIMD2(cos(a), sin(a)) * radius
        }
        return ShapeCandidate(
            kind: .regularPolygon, points: points, circle: nil, error: movement(from: p, to: points),
            note: "\(n) sides within \(Int(variation * 100 + 0.5))% of equal and every angle near \(Int(expected + 0.5))°"
        )
    }
}
