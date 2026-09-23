import Foundation
import simd

/// Turns an "outer polygon with one hole" into a single simple polygon by cutting a zero-width
/// bridge from the hole boundary to the outer boundary, so it can be triangulated with a plain
/// ear-clipping algorithm. This is the standard technique used to triangulate polygons with holes
/// without a full B-rep/CSG kernel — see GeometryKernel.swift for where it is used (through-hole and
/// through-cut features).
enum PolygonBridge {
    static func bridgeHole(outer: [SIMD2<Double>], hole: [SIMD2<Double>]) throws -> [SIMD2<Double>] {
        guard outer.count >= 3, hole.count >= 3 else {
            throw GeometryKernelError.invalidProfile("Outer and hole boundaries need at least 3 points")
        }
        let outerCCW = Triangulator.signedArea(outer) > 0 ? outer : outer.reversed()
        let holeCW = Triangulator.signedArea(hole) < 0 ? hole : hole.reversed()

        // Find the hole vertex closest to any outer vertex — a short, non-crossing bridge.
        var bestOuter = 0, bestHole = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (oi, o) in outerCCW.enumerated() {
            for (hi, h) in holeCW.enumerated() {
                let d = simd_distance_squared(o, h)
                if d < bestDist { bestDist = d; bestOuter = oi; bestHole = hi }
            }
        }

        // Walk the outer ring to the bridge point, loop fully around the hole back to that same
        // hole vertex (closing duplicate included), then continue the outer ring — this revisits
        // outer[bestOuter] exactly twice (the bridge's two sides) and hole[bestHole] exactly twice
        // (the hole loop's start/end), which is what makes the result a single simple polygon.
        var result: [SIMD2<Double>] = []
        result.append(contentsOf: outerCCW[0...bestOuter])
        result.append(contentsOf: holeCW[bestHole...] + holeCW[...bestHole])
        result.append(contentsOf: outerCCW[bestOuter...])
        return result
    }
}

/// Ear-clipping triangulation for simple (possibly non-convex) 2D polygons.
enum Triangulator {
    static func signedArea(_ pts: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        for i in 0..<pts.count {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2.0
    }

    /// Returns triangle indices (into `pts`) covering the polygon interior. Tolerant of the
    /// zero-width bridge edges produced by `PolygonBridge.bridgeHole` (duplicate/collinear points),
    /// which a naive strict-inequality ear test misclassifies as blocked forever.
    static func triangulate(_ pts: [SIMD2<Double>]) -> [Int] {
        guard pts.count >= 3 else { return [] }
        let eps = 1e-9
        var indices = Array(0..<pts.count)
        if signedArea(pts) < 0 { indices.reverse() }

        var triangles: [Int] = []
        var guardCount = 0
        let maxIterations = max(pts.count * pts.count, 200)
        while indices.count > 3, guardCount < maxIterations {
            guardCount += 1
            var earFound = false
            for i in 0..<indices.count {
                let iPrev = indices[(i + indices.count - 1) % indices.count]
                let iCur = indices[i]
                let iNext = indices[(i + 1) % indices.count]
                let a = pts[iPrev], b = pts[iCur], c = pts[iNext]
                if cross(b - a, c - a) <= eps { continue } // reflex or degenerate vertex, not an ear
                var containsOther = false
                for j in indices where j != iPrev && j != iCur && j != iNext {
                    if pointStrictlyInsideTriangle(pts[j], a, b, c, eps: eps) { containsOther = true; break }
                }
                if containsOther { continue }
                triangles.append(contentsOf: [iPrev, iCur, iNext])
                indices.remove(at: i)
                earFound = true
                break
            }
            if !earFound { break } // degenerate input; stop rather than loop forever
        }
        if indices.count == 3 {
            triangles.append(contentsOf: indices)
        }
        return triangles
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// True only for points strictly inside the triangle's interior — points on or within `eps` of
    /// an edge (as happens constantly along the zero-width bridge slit) do not count, so they never
    /// block a legitimate ear from being clipped.
    private static func pointStrictlyInsideTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, eps: Double) -> Bool {
        let d1 = cross(b - a, p - a)
        let d2 = cross(c - b, p - b)
        let d3 = cross(a - c, p - c)
        let allPositive = d1 > eps && d2 > eps && d3 > eps
        let allNegative = d1 < -eps && d2 < -eps && d3 < -eps
        return allPositive || allNegative
    }
}
