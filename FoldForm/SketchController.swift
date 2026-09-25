import Foundation
import Combine
import simd

enum SketchTool: String, CaseIterable, Identifiable {
    case line = "Line", rectangle = "Rectangle", circle = "Circle"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle"
        }
    }

    var hint: String {
        switch self {
        case .line: "Drag to draw a line. Close a loop of lines to make a shape."
        case .rectangle: "Drag from one corner to the opposite corner."
        case .circle: "Drag outward from the centre to set the size."
        }
    }
}

enum SketchShape: Equatable {
    case line(SIMD2<Float>, SIMD2<Float>)
    case rectangle(SIMD2<Float>, SIMD2<Float>)
    case circle(center: SIMD2<Float>, radius: Float)
}

/// The flat surface being drawn on. `u`, `v`, `n` are a right-handed set; `n` points toward the
/// viewer, which is the way shapes extrude.
struct SketchPlane: Equatable {
    var origin: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var n: SIMD3<Float>

    func world(_ p: SIMD2<Float>) -> SIMD3<Float> { origin + u * p.x + v * p.y }

    /// Where a ray meets the plane, in the plane's own coordinates.
    func point(origin rayOrigin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD2<Float>? {
        let denominator = simd_dot(direction, n)
        guard abs(denominator) > 1e-4 else { return nil }
        let t = simd_dot(origin - rayOrigin, n) / denominator
        guard t > 0 else { return nil }
        let hit = rayOrigin + direction * t - origin
        return SIMD2(simd_dot(hit, u), simd_dot(hit, v))
    }
}

enum SketchGeometry {
    static let circleSegments = 48
    static let minimumSize: Float = 0.002

    /// Closed outline of a rectangle or circle; a line has no outline.
    static func outline(of shape: SketchShape) -> [SIMD2<Float>]? {
        switch shape {
        case .line:
            return nil
        case .rectangle(let a, let c):
            return [a, SIMD2(c.x, a.y), c, SIMD2(a.x, c.y)]
        case .circle(let center, let radius):
            return (0..<circleSegments).map { i in
                let angle = Float(i) / Float(circleSegments) * 2 * .pi
                return center + SIMD2(cos(angle), sin(angle)) * radius
            }
        }
    }

    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Every closed shape in the sketch, counter-clockwise: rectangles, circles, and loops of lines
    /// whose ends meet (within `tolerance`) with exactly two lines at every corner.
    static func closedProfiles(_ shapes: [SketchShape], tolerance: Float) -> [[SIMD2<Float>]] {
        var profiles: [[SIMD2<Float>]] = []
        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        for shape in shapes {
            if case .line(let a, let b) = shape { segments.append((a, b)) }
            else if let outline = outline(of: shape) { profiles.append(outline) }
        }
        profiles += loops(of: segments, tolerance: tolerance)
        return profiles.compactMap { points in
            let area = signedArea(points)
            guard abs(area) > minimumSize * minimumSize else { return nil }
            return area < 0 ? points.reversed() : points
        }
    }

    private static func loops(of segments: [(SIMD2<Float>, SIMD2<Float>)], tolerance: Float) -> [[SIMD2<Float>]] {
        var nodes: [SIMD2<Float>] = []
        func node(for p: SIMD2<Float>) -> Int {
            if let i = nodes.firstIndex(where: { simd_distance($0, p) <= tolerance }) { return i }
            nodes.append(p)
            return nodes.count - 1
        }
        let edges = segments.map { (node(for: $0.0), node(for: $0.1)) }.filter { $0.0 != $0.1 }

        var neighbours = [[Int]](repeating: [], count: nodes.count)
        for (a, b) in edges { neighbours[a].append(b); neighbours[b].append(a) }

        var visited = Set<Int>()
        var result: [[SIMD2<Float>]] = []
        for start in nodes.indices where !visited.contains(start) && !neighbours[start].isEmpty {
            var component: [Int] = []
            var stack = [start]
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                component.append(current)
                stack += neighbours[current]
            }
            guard component.count >= 3, component.allSatisfy({ neighbours[$0].count == 2 }) else { continue }

            var ordered = [start]
            var previous = -1
            var current = start
            while true {
                guard let next = neighbours[current].first(where: { $0 != previous }) ?? neighbours[current].first else { break }
                if next == start { break }
                ordered.append(next)
                previous = current
                current = next
                if ordered.count > component.count { break }
            }
            if ordered.count == component.count { result.append(ordered.map { nodes[$0] }) }
        }
        return result
    }

    /// The nearest existing line end within `tolerance`, or the point itself.
    static func snapped(_ p: SIMD2<Float>, to shapes: [SketchShape], tolerance: Float) -> SIMD2<Float> {
        var best = p
        var bestDistance = tolerance
        for case .line(let a, let b) in shapes {
            for end in [a, b] where simd_distance(end, p) < bestDistance {
                best = end
                bestDistance = simd_distance(end, p)
            }
        }
        return best
    }

    /// A solid slab of `profile` pushed `depth` toward the viewer from the plane.
    static func slab(profile: [SIMD2<Float>], depth: Float, on plane: SketchPlane) -> RenderMesh {
        let outline = profile.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let local = GeometryBuilder.prism(outline: outline, height: Double(depth), centered: false)
        return local.placed(origin: plane.origin, u: plane.u, v: plane.v, n: plane.n)
    }
}

/// The drawing session: shapes on a plane, then extruding them into parts by dragging.
@MainActor
final class SketchController: ObservableObject {
    /// New parts start as a thin plate that can be bent.
    static let defaultDepth: Float = 0.008
    static let depthRange: ClosedRange<Float> = 0.002...0.15
    /// How close (in screen points) a line end must be to snap onto another.
    static let snapPoints: Float = 18

    @Published private(set) var isActive = false
    @Published var tool: SketchTool = .line
    @Published private(set) var shapes: [SketchShape] = []
    @Published private(set) var draft: SketchShape?
    @Published private(set) var plane: SketchPlane?
    @Published private(set) var isExtruding = false
    @Published private(set) var depth: Float = SketchController.defaultDepth

    /// World size of the snap radius, refreshed with every drag.
    private var snapTolerance: Float = 0.006

    func begin(on plane: SketchPlane) {
        self.plane = plane
        shapes = []
        draft = nil
        isExtruding = false
        depth = Self.defaultDepth
        isActive = true
    }

    func end() {
        isActive = false
        shapes = []
        draft = nil
        isExtruding = false
    }

    var profiles: [[SIMD2<Float>]] { SketchGeometry.closedProfiles(shapes, tolerance: snapTolerance) }
    var canExtrude: Bool { !profiles.isEmpty }

    /// A hint for whatever the user should do next.
    var prompt: String {
        if isExtruding { return "Slide up for thicker, down for thinner. Rotate and pan to look around, then tick to confirm." }
        if shapes.isEmpty { return tool.hint }
        return canExtrude ? "Drag more shapes, or tap Extrude." : "Close the loop to make a shape you can extrude."
    }

    // MARK: Drawing

    func dragBegan(at point: SIMD2<Float>, snapTolerance: Float) {
        guard isActive, !isExtruding else { return }
        self.snapTolerance = snapTolerance
        switch tool {
        case .line:
            let start = SketchGeometry.snapped(point, to: shapes, tolerance: snapTolerance)
            draft = .line(start, start)
        case .rectangle: draft = .rectangle(point, point)
        case .circle: draft = .circle(center: point, radius: 0)
        }
    }

    func dragChanged(to point: SIMD2<Float>, snapTolerance: Float) {
        guard let draft else { return }
        self.snapTolerance = snapTolerance
        switch draft {
        case .line(let start, _):
            self.draft = .line(start, SketchGeometry.snapped(point, to: shapes, tolerance: snapTolerance))
        case .rectangle(let corner, _):
            self.draft = .rectangle(corner, point)
        case .circle(let center, _):
            self.draft = .circle(center: center, radius: simd_distance(center, point))
        }
    }

    func dragEnded() {
        defer { draft = nil }
        guard let draft else { return }
        let minimum = SketchGeometry.minimumSize
        switch draft {
        case .line(let a, let b) where simd_distance(a, b) > minimum: shapes.append(draft)
        case .rectangle(let a, let c) where abs(a.x - c.x) > minimum && abs(a.y - c.y) > minimum: shapes.append(draft)
        case .circle(_, let radius) where radius > minimum: shapes.append(draft)
        default: break
        }
    }

    func cancelDrag() { draft = nil }

    func undoShape() {
        guard !shapes.isEmpty, !isExtruding else { return }
        shapes.removeLast()
    }

    // MARK: Extruding

    func startExtrude() {
        guard isActive, canExtrude else { return }
        depth = Self.defaultDepth
        isExtruding = true
    }

    func cancelExtrude() { isExtruding = false }

    /// Sets how far the shapes push out toward the viewer (driven by the slider).
    func setDepth(_ value: Float) {
        guard isExtruding else { return }
        depth = min(max(value, Self.depthRange.lowerBound), Self.depthRange.upperBound)
    }

    /// The solids the current shapes extrude into at the current depth.
    var extrusions: [RenderMesh] {
        guard let plane else { return [] }
        return profiles.map { SketchGeometry.slab(profile: $0, depth: depth, on: plane) }
    }

    /// Hands back the extruded solids and clears the drawing for the next shapes.
    func confirmExtrude() -> [RenderMesh] {
        let result = extrusions
        shapes = []
        draft = nil
        isExtruding = false
        return result
    }
}
