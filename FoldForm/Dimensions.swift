import SwiftUI
import simd

/// The unit dimensions are shown in. The scene itself is in metres.
enum DimensionUnit: String, CaseIterable, Identifiable {
    case millimetres = "mm", centimetres = "cm", metres = "m", inches = "in"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .millimetres: return "Millimetres (mm)"
        case .centimetres: return "Centimetres (cm)"
        case .metres: return "Metres (m)"
        case .inches: return "Inches (in)"
        }
    }
    private var perMetre: Double {
        switch self {
        case .millimetres: return 1000
        case .centimetres: return 100
        case .metres: return 1
        case .inches: return 1 / 0.0254
        }
    }
    private var decimals: Int { self == .metres ? 3 : (self == .millimetres ? 1 : 2) }

    func format(metres: Float) -> String {
        var text = String(format: "%.\(decimals)f", Double(metres) * perMetre)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return "\(text) \(rawValue)"
    }
}

/// One measured span: the label sits at its midpoint.
struct DimensionSegment: Equatable {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var length: Float { simd_distance(a, b) }
    var midpoint: SIMD3<Float> { (a + b) / 2 }
}

struct PartBounds: Equatable {
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>

    init?(_ mesh: RenderMesh) {
        guard var lo = mesh.positions.first else { return nil }
        var hi = lo
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        minimum = lo; maximum = hi
    }
}

enum DimensionBuilder {
    /// What to measure on a sketch shape: a line's length, a rectangle's two sides, a circle's diameter.
    static func segments(for shape: SketchShape, on plane: SketchPlane) -> [DimensionSegment] {
        func seg(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> DimensionSegment {
            DimensionSegment(a: plane.world(a), b: plane.world(b))
        }
        switch shape {
        case .line(let a, let b):
            return [seg(a, b)]
        case .rectangle(let a, let c):
            return [seg(a, SIMD2(c.x, a.y)), seg(SIMD2(c.x, a.y), c)]
        case .circle(let center, let radius):
            return [seg(center - SIMD2(radius, 0), center + SIMD2(radius, 0))]
        }
    }

    /// How far each shape being extruded pushes out, measured along the edge nearest the camera.
    static func extrusionSegments(profiles: [[SIMD2<Float>]], depth: Float, on plane: SketchPlane, cameraPosition: SIMD3<Float>) -> [DimensionSegment] {
        profiles.compactMap { profile in
            let start = profile.map(plane.world).min { simd_distance($0, cameraPosition) < simd_distance($1, cameraPosition) }
            return start.map { DimensionSegment(a: $0, b: $0 + plane.n * depth) }
        }
    }

    /// A part's overall length, height and depth, each along the box edge nearest the camera so the
    /// label lands on the side that can be seen.
    static func segments(for bounds: PartBounds, cameraPosition: SIMD3<Float>) -> [DimensionSegment] {
        let lo = bounds.minimum, hi = bounds.maximum
        var result: [DimensionSegment] = []
        for axis in 0..<3 {
            let others = (0..<3).filter { $0 != axis }
            var best: DimensionSegment?
            for i in 0..<2 {
                for j in 0..<2 {
                    var a = lo, b = hi
                    a[others[0]] = i == 0 ? lo[others[0]] : hi[others[0]]
                    a[others[1]] = j == 0 ? lo[others[1]] : hi[others[1]]
                    b[others[0]] = a[others[0]]
                    b[others[1]] = a[others[1]]
                    let candidate = DimensionSegment(a: a, b: b)
                    if best == nil || simd_distance(candidate.midpoint, cameraPosition) < simd_distance(best!.midpoint, cameraPosition) {
                        best = candidate
                    }
                }
            }
            if let best, best.length > 1e-5 { result.append(best) }
        }
        return result
    }
}

/// Measurement lines and labels drawn over the 3D view. Touches pass through.
struct DimensionOverlay: View {
    @ObservedObject var viewport: ViewportEntities
    @ObservedObject var sketch: SketchController
    let unit: DimensionUnit

    private static let outline = Color(white: 0.5)
    private static let ink = Color.primary

    var body: some View {
        Canvas { context, size in
            let camera = viewport.camera
            var segments: [DimensionSegment] = []
            for bounds in viewport.partBounds {
                segments += DimensionBuilder.segments(for: bounds, cameraPosition: camera.position)
            }
            if let plane = sketch.plane {
                for shape in sketch.shapes + (sketch.draft.map { [$0] } ?? []) {
                    segments += DimensionBuilder.segments(for: shape, on: plane)
                }
                if sketch.isExtruding {
                    segments += DimensionBuilder.extrusionSegments(profiles: sketch.profiles, depth: sketch.isCutting ? -sketch.depth : sketch.depth, on: plane, cameraPosition: camera.position)
                }
            }
            for segment in segments {
                guard let a = camera.project(segment.a, in: size),
                      let b = camera.project(segment.b, in: size),
                      let m = camera.project(segment.midpoint, in: size) else { continue }
                var line = Path()
                line.move(to: a); line.addLine(to: b)
                context.stroke(line, with: .color(Self.outline), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                for end in [a, b] {
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)), with: .color(Self.outline))
                }
                let text = context.resolve(
                    Text(unit.format(metres: segment.length))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.ink)
                )
                let textSize = text.measure(in: CGSize(width: 200, height: 40))
                let pill = CGRect(x: m.x - textSize.width / 2 - 6, y: m.y - textSize.height / 2 - 3,
                                  width: textSize.width + 12, height: textSize.height + 6)
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(.secondarySystemBackground)))
                context.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Self.outline), lineWidth: 1.5)
                context.draw(text, at: m)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
