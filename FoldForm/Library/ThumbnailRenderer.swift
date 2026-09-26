import UIKit
import simd

/// Draws a design as a flat-shaded picture, from a fixed three-quarter view, straight from its
/// meshes. No GPU or live scene needed, so it works headless and is testable.
enum ThumbnailRenderer {
    struct Body {
        var mesh: RenderMesh
        var rgb: SIMD3<Float>
    }

    static let defaultRGB = SIMD3<Float>(0.16, 0.42, 0.95)
    static let triangleBudget = 40_000

    private struct Triangle {
        var a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>
        var depth: Float
        var color: SIMD3<Float>
    }

    static func render(_ bodies: [Body], size: CGSize = CGSize(width: 480, height: 360), scale: CGFloat = 2) -> UIImage? {
        let drawable = bodies.filter { !$0.mesh.positions.isEmpty && $0.mesh.indices.count >= 3 }
        guard !drawable.isEmpty else { return nil }

        var lo = drawable[0].mesh.boundingBox.min, hi = drawable[0].mesh.boundingBox.max
        for body in drawable { let b = body.mesh.boundingBox; lo = simd_min(lo, b.min); hi = simd_max(hi, b.max) }
        let centre = (lo + hi) / 2

        let toCamera = simd_normalize(SIMD3<Float>(1.1, 0.85, 1.4))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), toCamera))
        let up = simd_cross(toCamera, right)
        let light = simd_normalize(toCamera + up * 0.6 + right * 0.3)

        let total = drawable.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        let step = max(1, total / triangleBudget + (total % triangleBudget == 0 ? 0 : 1))

        var triangles: [Triangle] = []
        triangles.reserveCapacity(min(total, triangleBudget + 1))
        for body in drawable {
            let mesh = body.mesh
            var t = 0
            while t + 2 < mesh.indices.count {
                let i0 = Int(mesh.indices[t]), i1 = Int(mesh.indices[t + 1]), i2 = Int(mesh.indices[t + 2])
                t += 3 * step
                guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
                let p0 = mesh.positions[i0] - centre, p1 = mesh.positions[i1] - centre, p2 = mesh.positions[i2] - centre
                let normal = simd_cross(p1 - p0, p2 - p0)
                let length = simd_length(normal)
                guard length > 1e-12 else { continue }
                let shade = 0.42 + 0.58 * abs(simd_dot(normal / length, light))
                func project(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(simd_dot(p, right), simd_dot(p, up)) }
                triangles.append(Triangle(
                    a: project(p0), b: project(p1), c: project(p2),
                    depth: simd_dot(p0 + p1 + p2, toCamera) / 3, color: body.rgb * shade))
            }
        }
        guard !triangles.isEmpty else { return nil }

        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for tri in triangles { for p in [tri.a, tri.b, tri.c] {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        } }
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        let fit = Float(min(size.width * 0.78 / CGFloat(spanX), size.height * 0.78 / CGFloat(spanY)))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        func screen(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat((p.x - midX) * fit), y: size.height / 2 - CGFloat((p.y - midY) * fit))
        }

        triangles.sort { $0.depth < $1.depth }   // far first, so nearer faces paint over them

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setLineJoin(.round)
            cg.setLineWidth(0.6)
            for tri in triangles {
                let color = UIColor(red: CGFloat(min(tri.color.x, 1)), green: CGFloat(min(tri.color.y, 1)), blue: CGFloat(min(tri.color.z, 1)), alpha: 1)
                cg.setFillColor(color.cgColor)
                cg.setStrokeColor(color.cgColor)   // a hairline in the same colour hides seams between triangles
                cg.beginPath()
                cg.move(to: screen(tri.a)); cg.addLine(to: screen(tri.b)); cg.addLine(to: screen(tri.c)); cg.closePath()
                cg.drawPath(using: .fillStroke)
            }
        }
    }
}
