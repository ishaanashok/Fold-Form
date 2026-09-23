import Foundation
import simd

/// A single sketch entity, positioned in the sketch plane's own 2D coordinate system.
enum SketchEntity: Identifiable, Equatable {
    case line(id: UUID, p1: SIMD2<Double>, p2: SIMD2<Double>, construction: Bool)
    case rectangle(id: UUID, origin: SIMD2<Double>, width: Double, height: Double, construction: Bool)
    case circle(id: UUID, center: SIMD2<Double>, radius: Double, construction: Bool)
    case arc(id: UUID, center: SIMD2<Double>, radius: Double, startRadians: Double, endRadians: Double, construction: Bool)
    case polygon(id: UUID, points: [SIMD2<Double>], construction: Bool)

    var id: UUID {
        switch self {
        case .line(let id, _, _, _), .rectangle(let id, _, _, _, _), .circle(let id, _, _, _),
             .arc(let id, _, _, _, _, _), .polygon(let id, _, _):
            return id
        }
    }

    var isConstruction: Bool {
        switch self {
        case .line(_, _, _, let c), .rectangle(_, _, _, _, let c), .circle(_, _, _, let c),
             .arc(_, _, _, _, _, let c), .polygon(_, _, let c):
            return c
        }
    }
}

/// A lightweight constraint record. The prototype preserves and reports these without a full
/// numerical solver (see plan section "Sketch workflow": "the prototype must at minimum preserve
/// constraints, report under-constrained geometry, and reject contradictory input").
enum SketchConstraintKind: String, Codable {
    case coincident, horizontal, vertical, parallel, perpendicular, tangent, equal
    case concentric, midpoint, symmetry, fixed, construction, dimensional
}

struct SketchConstraint: Identifiable, Equatable {
    let id: UUID = UUID()
    var kind: SketchConstraintKind
    var entityIDs: [UUID]
    var value: Double? // used by .dimensional
}

enum SketchProfileError: Error, LocalizedError, Equatable {
    case empty
    case open(String)
    case selfIntersecting

    var errorDescription: String? {
        switch self {
        case .empty: return "Sketch has no non-construction geometry"
        case .open(let detail): return "Profile is open: \(detail)"
        case .selfIntersecting: return "Profile is self-intersecting"
        }
    }
}

struct Sketch: Identifiable, Equatable {
    let id: UUID
    var name: String
    var planeID: UUID
    var entities: [SketchEntity] = []
    var constraints: [SketchConstraint] = []
    var isFullyConstrained: Bool = false

    init(id: UUID = UUID(), name: String, planeID: UUID) {
        self.id = id
        self.name = name
        self.planeID = planeID
    }

    /// Resolves the sketch's solid, non-construction geometry into one closed profile.
    /// Only a single closed loop per sketch is supported by this first modeling foundation
    /// (matches GeometryKernel's current extrude/hole scope); additional loops are reported,
    /// not silently dropped.
    func resolveClosedProfile() throws -> PlanarProfile {
        let solids = entities.filter { !$0.isConstruction }
        guard !solids.isEmpty else { throw SketchProfileError.empty }

        if solids.count == 1 {
            switch solids[0] {
            case .rectangle(_, let origin, let w, let h, _):
                return .rectangle(width: w, height: h).translated(by: origin)
            case .circle(_, let center, let r, _):
                return .circle(radius: r).translated(by: center)
            case .polygon(_, let pts, _):
                guard pts.count >= 3 else { throw SketchProfileError.open("Polygon needs at least 3 points") }
                return .polygon(points: pts)
            case .arc:
                throw SketchProfileError.open("A single arc cannot form a closed profile")
            case .line:
                throw SketchProfileError.open("A single line cannot form a closed profile")
            }
        }

        // Multiple line/arc segments: verify they chain into exactly one closed loop.
        let lines: [(SIMD2<Double>, SIMD2<Double>)] = solids.compactMap {
            if case .line(_, let p1, let p2, _) = $0 { return (p1, p2) }
            return nil
        }
        guard lines.count == solids.count else {
            throw SketchProfileError.open("Mixing multiple primitive types in one profile is not yet supported")
        }
        let loop = try Self.chainIntoLoop(lines)
        return .polygon(points: loop)
    }

    private static func chainIntoLoop(_ segments: [(SIMD2<Double>, SIMD2<Double>)]) throws -> [SIMD2<Double>] {
        guard segments.count >= 3 else { throw SketchProfileError.open("Need at least 3 segments") }
        var loop = [segments[0].0]
        var current = segments[0].1
        loop.append(current)
        var remaining = Array(segments.dropFirst())
        let tolerance = 1e-6
        while !remaining.isEmpty {
            guard let idx = remaining.firstIndex(where: { simd_distance($0.0, current) < tolerance || simd_distance($0.1, current) < tolerance }) else {
                throw SketchProfileError.open("Segments do not chain into a single closed loop")
            }
            let seg = remaining.remove(at: idx)
            let next = simd_distance(seg.0, current) < tolerance ? seg.1 : seg.0
            current = next
            loop.append(current)
        }
        guard simd_distance(current, segments[0].0) < tolerance else {
            throw SketchProfileError.open("Loop does not return to its starting point")
        }
        loop.removeLast() // last point duplicates the first
        return loop
    }
}

extension PlanarProfile {
    func translated(by offset: SIMD2<Double>) -> PlanarProfile {
        guard offset != .zero else { return self }
        switch self {
        case .rectangle, .circle:
            // Rectangle/circle are always authored centered at their own origin for the kernel;
            // sketch-plane placement offset is preserved by wrapping as an explicit polygon.
            let segments = 48
            switch self {
            case .rectangle(let w, let h):
                let pts: [SIMD2<Double>] = [
                    .init(-w / 2, -h / 2), .init(w / 2, -h / 2), .init(w / 2, h / 2), .init(-w / 2, h / 2)
                ].map { $0 + offset }
                return .polygon(points: pts)
            case .circle(let r):
                let pts: [SIMD2<Double>] = (0..<segments).map { i in
                    let a = Double(i) / Double(segments) * 2 * .pi
                    return SIMD2<Double>(cos(a) * r, sin(a) * r) + offset
                }
                return .polygon(points: pts)
            default: return self
            }
        case .polygon(let pts):
            return .polygon(points: pts.map { $0 + offset })
        }
    }
}
