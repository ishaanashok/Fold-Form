import Foundation
import simd

/// A single tessellated body ready for RealityKit presentation.
/// Positions are in the Part Studio's local meters, +y up, bend axis along local x = 0 (see BendDeformer.swift).
struct RenderMesh: Equatable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]

    static let empty = RenderMesh(positions: [], normals: [], indices: [])

    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = positions.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }
}

/// An evaluated solid body produced by the geometry kernel.
/// `kind` records enough provenance for later features (Hole, Boolean) to know what operations are geometrically valid.
struct Solid: Identifiable, Equatable {
    let id: UUID
    var mesh: RenderMesh
    var kind: SolidKind

    init(id: UUID = UUID(), mesh: RenderMesh, kind: SolidKind) {
        self.id = id
        self.mesh = mesh
        self.kind = kind
    }
}

/// Provenance of a solid, sufficient for the procedural kernel to validate follow-on operations
/// (e.g. a hole can only be cut through a prism whose axis is known) without a full B-rep.
indirect enum SolidKind: Equatable {
    case primitiveBox(width: Double, height: Double, depth: Double)
    case primitiveCylinder(radius: Double, height: Double)
    case primitiveSphere(radius: Double)
    case primitiveWedge(width: Double, height: Double, depth: Double)
    /// A solid extruded from a planar profile along `axis` (in the profile plane's local Z), full length `length`.
    case prism(profile: PlanarProfile, axis: SIMD3<Float>, length: Double)
    /// A prism with one or more circular through-holes cut along its extrusion axis.
    case prismWithHoles(base: PlanarProfile, axis: SIMD3<Float>, length: Double, holes: [HoleDefinition])
}

/// A 2D profile authored on a sketch plane, in the plane's own 2D coordinates (millimeters... here meters for RealityKit scale, see PartProfile).
enum PlanarProfile: Equatable {
    case rectangle(width: Double, height: Double)
    case circle(radius: Double)
    case polygon(points: [SIMD2<Double>])

    var isClosed: Bool { true } // rectangle/circle always closed; polygon validated at sketch time.

    var area: Double {
        switch self {
        case .rectangle(let w, let h): return w * h
        case .circle(let r): return .pi * r * r
        case .polygon(let pts): return PlanarProfile.shoelaceArea(pts)
        }
    }

    static func shoelaceArea(_ pts: [SIMD2<Double>]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<pts.count {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2.0
    }
}

enum ExtrudeResultType: Equatable {
    case new
    case add(targetBodyID: UUID)
    case remove(targetBodyID: UUID)
    case intersect(targetBodyID: UUID)
}

enum ExtrudeTermination: Equatable {
    case blind(distance: Double)
    case symmetric(distance: Double)
    case throughAll
    case upToNext
    case upToFace(faceID: UUID)
}

struct ExtrudeParameters: Equatable {
    var termination: ExtrudeTermination
    var resultType: ExtrudeResultType
    var reversed: Bool = false
}

enum RevolveResultType: Equatable {
    case new
    case add(targetBodyID: UUID)
    case remove(targetBodyID: UUID)
    case intersect(targetBodyID: UUID)
}

struct RevolveParameters: Equatable {
    var angleRadians: Double
    var resultType: RevolveResultType
}

enum HoleType: Equatable {
    case simple
    case counterbore(diameter: Double, depth: Double)
    case countersink(diameter: Double, angleRadians: Double)
    case tapped(threadNoteOnly: Bool = true)
}

struct HoleDefinition: Equatable {
    /// Center of the hole in the target face's local 2D coordinates.
    var center: SIMD2<Double>
    var diameter: Double
    var type: HoleType = .simple
    var throughAll: Bool = true
    var depth: Double? = nil // used when throughAll == false
}

enum BooleanOperation: Equatable {
    case union
    case subtract
    case intersect
}

enum PrimitiveDefinition: Equatable {
    case box(width: Double, height: Double, depth: Double)
    case cylinder(radius: Double, height: Double)
    case sphere(radius: Double)
    case wedge(width: Double, height: Double, depth: Double)
}

struct FilletDefinition: Equatable { var edgeIDs: [UUID]; var radius: Double }
struct ChamferDefinition: Equatable { var edgeIDs: [UUID]; var distance: Double; var angleRadians: Double? }
struct ShellDefinition: Equatable { var openFaceIDs: [UUID]; var thickness: Double }
struct DraftDefinition: Equatable { var faceIDs: [UUID]; var neutralPlaneID: UUID; var angleRadians: Double }
struct PatternDefinition: Equatable { var featureIDs: [UUID]; var count: Int; var spacing: Double }
struct MirrorDefinition: Equatable { var featureIDs: [UUID]; var planeID: UUID }
struct TransformDefinition: Equatable { var bodyID: UUID; var translation: SIMD3<Double>; var rotationRadians: SIMD3<Double> }

enum GeometryKernelError: Error, LocalizedError, Equatable {
    case unsupportedOperation(String)
    case invalidProfile(String)
    case bodyNotFound
    case incompatibleGeometry(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let detail): return "Not yet implemented: \(detail)"
        case .invalidProfile(let detail): return "Invalid profile: \(detail)"
        case .bodyNotFound: return "Referenced body no longer exists"
        case .incompatibleGeometry(let detail): return "Unsupported geometry combination: \(detail)"
        }
    }
}
