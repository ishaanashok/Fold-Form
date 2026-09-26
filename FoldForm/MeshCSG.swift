import simd

/// Subtracts one closed triangle mesh from another with a BSP tree. Meant for the simple cutters the
/// sketch tools make (extruded rectangles, circles, closed line loops), which is what "remove" needs.
enum MeshCSG {
    private static let epsilon = 1e-7

    static func subtract(_ a: RenderMesh, _ b: RenderMesh) -> RenderMesh {
        let aPolys = polygons(of: a), bPolys = polygons(of: b)
        guard !aPolys.isEmpty else { return .empty }
        guard !bPolys.isEmpty else { return a }
        let nodeA = Node(aPolys), nodeB = Node(bPolys)
        nodeA.invert()
        nodeA.clipTo(nodeB)
        nodeB.clipTo(nodeA)
        nodeB.invert()
        nodeB.clipTo(nodeA)
        nodeB.invert()
        nodeA.build(nodeB.allPolygons())
        nodeA.invert()
        return mesh(from: nodeA.allPolygons())
    }

    // MARK: Polygons

    private struct Plane {
        var normal: SIMD3<Double>
        var w: Double

        init?(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 1e-14 else { return nil }
            normal = n / length
            w = simd_dot(normal, a)
        }

        func flipped() -> Plane { var p = self; p.normal = -normal; p.w = -w; return p }
    }

    private struct Polygon {
        var vertices: [SIMD3<Double>]
        var plane: Plane
    }

    private static func polygons(of mesh: RenderMesh) -> [Polygon] {
        var result: [Polygon] = []
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[i])])
            let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 2])])
            if let plane = Plane(a, b, c) { result.append(Polygon(vertices: [a, b, c], plane: plane)) }
            i += 3
        }
        return result
    }

    private static func mesh(from polygons: [Polygon]) -> RenderMesh {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for polygon in polygons where polygon.vertices.count >= 3 {
            let base = UInt32(positions.count)
            let normal = SIMD3<Float>(polygon.plane.normal)
            for v in polygon.vertices { positions.append(SIMD3<Float>(v)); normals.append(normal) }
            for k in 1..<(polygon.vertices.count - 1) {
                indices += [base, base + UInt32(k), base + UInt32(k + 1)]
            }
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: BSP

    private final class Node {
        var plane: Plane?
        var front: Node?
        var back: Node?
        var polygons: [Polygon] = []

        init(_ list: [Polygon]) { if !list.isEmpty { build(list) } }

        func invert() {
            for i in polygons.indices {
                polygons[i].vertices.reverse()
                polygons[i].plane = polygons[i].plane.flipped()
            }
            plane = plane?.flipped()
            front?.invert()
            back?.invert()
            swap(&front, &back)
        }

        func clip(_ list: [Polygon]) -> [Polygon] {
            guard let plane else { return list }
            var frontList: [Polygon] = [], backList: [Polygon] = []
            for polygon in list {
                let r = MeshCSG.split(polygon, by: plane)
                frontList += r.coplanarFront + r.front
                backList += r.coplanarBack + r.back
            }
            let f = front?.clip(frontList) ?? frontList
            let b = back?.clip(backList) ?? []
            return f + b
        }

        func clipTo(_ other: Node) {
            polygons = other.clip(polygons)
            front?.clipTo(other)
            back?.clipTo(other)
        }

        func allPolygons() -> [Polygon] {
            polygons + (front?.allPolygons() ?? []) + (back?.allPolygons() ?? [])
        }

        func build(_ list: [Polygon]) {
            guard !list.isEmpty else { return }
            if plane == nil { plane = list[0].plane }
            var frontList: [Polygon] = [], backList: [Polygon] = []
            for polygon in list {
                let r = MeshCSG.split(polygon, by: plane!)
                polygons += r.coplanarFront + r.coplanarBack
                frontList += r.front
                backList += r.back
            }
            if !frontList.isEmpty {
                if front == nil { front = Node([]) }
                front!.build(frontList)
            }
            if !backList.isEmpty {
                if back == nil { back = Node([]) }
                back!.build(backList)
            }
        }
    }

    private struct SplitResult {
        var coplanarFront: [Polygon] = [], coplanarBack: [Polygon] = []
        var front: [Polygon] = [], back: [Polygon] = []
    }

    private static func split(_ polygon: Polygon, by plane: Plane) -> SplitResult {
        var result = SplitResult()
        let coplanar = 0, frontSide = 1, backSide = 2, spanning = 3
        var polygonType = 0
        var types: [Int] = []
        for v in polygon.vertices {
            let t = simd_dot(plane.normal, v) - plane.w
            let type = t < -epsilon ? backSide : (t > epsilon ? frontSide : coplanar)
            polygonType |= type
            types.append(type)
        }
        switch polygonType {
        case coplanar:
            if simd_dot(plane.normal, polygon.plane.normal) > 0 { result.coplanarFront.append(polygon) } else { result.coplanarBack.append(polygon) }
        case frontSide:
            result.front.append(polygon)
        case backSide:
            result.back.append(polygon)
        default:
            var f: [SIMD3<Double>] = [], b: [SIMD3<Double>] = []
            let count = polygon.vertices.count
            for i in 0..<count {
                let j = (i + 1) % count
                let ti = types[i], tj = types[j]
                let vi = polygon.vertices[i], vj = polygon.vertices[j]
                if ti != backSide { f.append(vi) }
                if ti != frontSide { b.append(vi) }
                if (ti | tj) == spanning {
                    let t = (plane.w - simd_dot(plane.normal, vi)) / simd_dot(plane.normal, vj - vi)
                    let v = vi + (vj - vi) * t
                    f.append(v); b.append(v)
                }
            }
            if f.count >= 3 { result.front.append(Polygon(vertices: f, plane: polygon.plane)) }
            if b.count >= 3 { result.back.append(Polygon(vertices: b, plane: polygon.plane)) }
        }
        return result
    }
}
