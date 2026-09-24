import SwiftUI
import simd

/// A small cube in the corner that mirrors the camera's orientation. Tap a face to snap the view
/// straight onto that side of the block.
struct ViewCubeView: View {
    let axes: ViewAxes
    let onSelect: (ViewFace) -> Void

    private let side: CGFloat = 96

    private struct ProjectedFace {
        var face: ViewFace
        var corners: [CGPoint]
        var shade: Double
    }

    private func project(_ v: SIMD3<Float>) -> CGPoint {
        let scale = Float(side) * 0.26
        return CGPoint(
            x: CGFloat(side / 2) + CGFloat(simd_dot(v, axes.right) * scale),
            y: CGFloat(side / 2) - CGFloat(simd_dot(v, axes.up) * scale)
        )
    }

    /// Faces turned toward the viewer, which for a convex cube are exactly the ones to draw.
    private var visibleFaces: [ProjectedFace] {
        ViewFace.allCases.compactMap { face in
            let facing = -simd_dot(face.normal, axes.forward)
            guard facing > 0.001 else { return nil }
            let n = face.normal, (u, v) = face.tangents
            let corners = [n + u + v, n - u + v, n - u - v, n + u - v].map(project)
            return ProjectedFace(face: face, corners: corners, shade: Double(facing))
        }
    }

    var body: some View {
        Canvas { context, _ in
            for item in visibleFaces {
                var path = Path()
                path.move(to: item.corners[0])
                item.corners.dropFirst().forEach { path.addLine(to: $0) }
                path.closeSubpath()
                context.fill(path, with: .color(Color(white: 0.42 + 0.4 * item.shade)))
                context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 1)

                let center = CGPoint(
                    x: item.corners.map(\.x).reduce(0, +) / 4,
                    y: item.corners.map(\.y).reduce(0, +) / 4
                )
                let label = Text(item.face.title)
                    .font(.system(size: 8 + 3 * item.shade, weight: .bold))
                    .foregroundColor(.black.opacity(0.4 + 0.5 * item.shade))
                context.draw(label, at: center)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { tap in
                // Front-most face under the finger (largest facing = closest to the viewer).
                let hits = visibleFaces.filter { Self.contains($0.corners, tap.location) }
                if let hit = hits.max(by: { $0.shade < $1.shade }) { onSelect(hit.face) }
            }
        )
        .accessibilityElement()
        .accessibilityLabel("View cube")
        .accessibilityIdentifier("viewCube")
    }

    /// Point-in-convex-quad test.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = Double((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x))
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return true
    }
}
