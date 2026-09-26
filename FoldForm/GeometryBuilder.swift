import Foundation
import simd

/// Procedural mesh construction. Coordinate convention (must match BendDeformer.swift):
/// local X = signed distance from the bend axis/crease, local Y = thickness, local Z = length
/// along the crease. A 2D sketch profile lives in the XY plane; extrusion runs along +Z.
enum GeometryBuilder {

    // MARK: Primitives

    static func box(width: Double, height: Double, depth: Double) -> RenderMesh {
        let outline: [SIMD2<Double>] = [
            .init(-width / 2, -height / 2), .init(width / 2, -height / 2),
            .init(width / 2, height / 2), .init(-width / 2, height / 2)
        ]
        return prism(outline: outline, height: depth, centered: true)
    }

    static func cylinder(radius: Double, height: Double, segments: Int = 32) -> RenderMesh {
        let outline: [SIMD2<Double>] = (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return .init(cos(a) * radius, sin(a) * radius)
        }
        return prism(outline: outline, height: height, centered: true)
    }

    static func sphere(radius: Double, latSegments: Int = 12, lonSegments: Int = 24) -> RenderMesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for lat in 0...latSegments {
            let theta = Double(lat) / Double(latSegments) * .pi
            for lon in 0...lonSegments {
                let phi = Double(lon) / Double(lonSegments) * 2 * .pi
                let x = sin(theta) * cos(phi) * radius
                let y = cos(theta) * radius
                let z = sin(theta) * sin(phi) * radius
                let p = SIMD3<Float>(Float(x), Float(y), Float(z))
                positions.append(p)
                normals.append(simd_normalize(p))
            }
        }
        let stride = lonSegments + 1
        for lat in 0..<latSegments {
            for lon in 0..<lonSegments {
                let a = UInt32(lat * stride + lon)
                let b = UInt32(a) + UInt32(stride)
                let c = a + 1
                let d = b + 1
                indices.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    static func wedge(width: Double, height: Double, depth: Double) -> RenderMesh {
        // Right-triangle cross-section (ramp), extruded along Z.
        let outline: [SIMD2<Double>] = [
            .init(-width / 2, -height / 2), .init(width / 2, -height / 2), .init(-width / 2, height / 2)
        ]
        return prism(outline: outline, height: depth, centered: true)
    }

    // MARK: Prism from a simple convex or concave 2D outline (no hole)

    static func prism(outline: [SIMD2<Double>], height: Double, centered: Bool) -> RenderMesh {
        let z0 = centered ? -height / 2 : 0
        let z1 = centered ? height / 2 : height
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Caps
        let capTriangles = Triangulator.triangulate(outline)
        appendCap(outline, z: z0, triangles: capTriangles, flip: true, positions: &positions, normals: &normals, indices: &indices)
        appendCap(outline, z: z1, triangles: capTriangles, flip: false, positions: &positions, normals: &normals, indices: &indices)

        // Side walls
        appendSideWalls(outline, z0: z0, z1: z1, positions: &positions, normals: &normals, indices: &indices)

        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: Prism with any number of holes

    /// A prism from an outer outline and holes, with the caps triangulated by bridging each hole into
    /// the outline. Extrudes along +Z from 0 to `height` (or centred on 0).
    static func prism(outer: [SIMD2<Double>], holes: [[SIMD2<Double>]], height: Double, centered: Bool) throws -> RenderMesh {
        let z0 = centered ? -height / 2 : 0
        let z1 = centered ? height / 2 : height
        // Walls face outward only for a counter-clockwise outline.
        let outerCCW = Triangulator.signedArea(outer) > 0 ? outer : Array(outer.reversed())
        guard !holes.isEmpty else { return prism(outline: outerCCW, height: height, centered: centered) }
        let holesCW = holes.map { Triangulator.signedArea($0) < 0 ? $0 : Array($0.reversed()) }
        var polygon = outerCCW
        for hole in holesCW { polygon = try PolygonBridge.bridgeHole(outer: polygon, hole: hole) }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let capTriangles = Triangulator.triangulate(polygon)
        appendCap(polygon, z: z0, triangles: capTriangles, flip: true, positions: &positions, normals: &normals, indices: &indices)
        appendCap(polygon, z: z1, triangles: capTriangles, flip: false, positions: &positions, normals: &normals, indices: &indices)
        appendSideWalls(outerCCW, z0: z0, z1: z1, positions: &positions, normals: &normals, indices: &indices)
        // A clockwise hole's walls face into the hole, away from the material.
        for hole in holesCW { appendSideWalls(hole, z0: z0, z1: z1, positions: &positions, normals: &normals, indices: &indices) }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: Prism whose caps have a single bridged hole (see PolygonBridge)

    static func prismWithBoreCap(capPolygon: [SIMD2<Double>], outerOutline: [SIMD2<Double>], holeOutline: [SIMD2<Double>], height: Double) -> RenderMesh {
        let z0 = -height / 2
        let z1 = height / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let capTriangles = Triangulator.triangulate(capPolygon)
        appendCap(capPolygon, z: z0, triangles: capTriangles, flip: true, positions: &positions, normals: &normals, indices: &indices)
        appendCap(capPolygon, z: z1, triangles: capTriangles, flip: false, positions: &positions, normals: &normals, indices: &indices)

        appendSideWalls(outerOutline, z0: z0, z1: z1, positions: &positions, normals: &normals, indices: &indices)
        // Bore wall winds opposite the outer wall so its normal points inward, into the hole.
        appendSideWalls(holeOutline.reversed(), z0: z0, z1: z1, positions: &positions, normals: &normals, indices: &indices)

        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: - Helpers

    private static func appendCap(_ outline: [SIMD2<Double>], z: Double, triangles: [Int], flip: Bool, positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>], indices: inout [UInt32]) {
        let base = UInt32(positions.count)
        let normal = SIMD3<Float>(0, 0, flip ? -1 : 1)
        for p in outline {
            positions.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(z)))
            normals.append(normal)
        }
        var tri = triangles
        if flip {
            // Reverse winding for the bottom cap so it faces -Z outward.
            tri = stride(from: 0, to: triangles.count, by: 3).flatMap { [triangles[$0], triangles[$0 + 2], triangles[$0 + 1]] }
        }
        indices.append(contentsOf: tri.map { base + UInt32($0) })
    }

    private static func appendSideWalls(_ outline: [SIMD2<Double>], z0: Double, z1: Double, positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>], indices: inout [UInt32]) {
        let count = outline.count
        for i in 0..<count {
            let a = outline[i]
            let b = outline[(i + 1) % count]
            let edge = b - a
            let outward = simd_normalize(SIMD2<Double>(edge.y, -edge.x))
            let n = SIMD3<Float>(Float(outward.x), Float(outward.y), 0)

            let base = UInt32(positions.count)
            positions.append(SIMD3<Float>(Float(a.x), Float(a.y), Float(z0)))
            positions.append(SIMD3<Float>(Float(b.x), Float(b.y), Float(z0)))
            positions.append(SIMD3<Float>(Float(b.x), Float(b.y), Float(z1)))
            positions.append(SIMD3<Float>(Float(a.x), Float(a.y), Float(z1)))
            normals.append(contentsOf: [n, n, n, n])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
    }
}
