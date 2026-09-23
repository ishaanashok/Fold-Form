import Foundation
import simd

/// Abstraction over solid modeling operations, independent of RealityKit, so the procedural
/// implementation below can later be swapped for a real B-rep/CSG kernel without touching the
/// iPhone Duo presentation layer (RealityViewport, BendDeformer, CollisionManager).
///
/// Scope note (see plan section 13, "CAD-kernel scope"): this first implementation is honest about
/// what it can and cannot resolve. Supported today: primitives, extrusion of rectangle/circle/convex
/// polygon profiles, boolean-style through-all hole/pocket cuts on prismatic bodies, and simple
/// non-overlapping unions. Anything else throws `GeometryKernelError.unsupportedOperation` with the
/// feature left intact and in an error state, per the plan's explicit instruction not to fake success.
protocol GeometryKernel {
    func makePrimitive(_ definition: PrimitiveDefinition) throws -> Solid
    func extrude(_ profile: PlanarProfile, _ parameters: ExtrudeParameters, into bodies: [UUID: Solid]) throws -> Solid
    func revolve(_ profile: PlanarProfile, _ parameters: RevolveParameters) throws -> Solid
    func boolean(_ operation: BooleanOperation, _ lhs: Solid, _ rhs: Solid) throws -> Solid
    func createHole(_ definition: HoleDefinition, in solid: Solid) throws -> Solid
    func fillet(_ definition: FilletDefinition, in solid: Solid) throws -> Solid
    func chamfer(_ definition: ChamferDefinition, in solid: Solid) throws -> Solid
    func shell(_ definition: ShellDefinition, in solid: Solid) throws -> Solid
    func tessellate(_ solid: Solid) throws -> RenderMesh
}

struct ProceduralGeometryKernel: GeometryKernel {

    // MARK: - Primitives

    func makePrimitive(_ definition: PrimitiveDefinition) throws -> Solid {
        switch definition {
        case .box(let w, let h, let d):
            return Solid(mesh: GeometryBuilder.box(width: w, height: h, depth: d), kind: .primitiveBox(width: w, height: h, depth: d))
        case .cylinder(let r, let h):
            return Solid(mesh: GeometryBuilder.cylinder(radius: r, height: h), kind: .primitiveCylinder(radius: r, height: h))
        case .sphere(let r):
            return Solid(mesh: GeometryBuilder.sphere(radius: r), kind: .primitiveSphere(radius: r))
        case .wedge(let w, let h, let d):
            return Solid(mesh: GeometryBuilder.wedge(width: w, height: h, depth: d), kind: .primitiveWedge(width: w, height: h, depth: d))
        }
    }

    // MARK: - Extrude

    func extrude(_ profile: PlanarProfile, _ parameters: ExtrudeParameters, into bodies: [UUID: Solid]) throws -> Solid {
        guard case .polygon(let pts) = normalizedPolygon(profile), pts.count >= 3 else {
            throw GeometryKernelError.invalidProfile("Profile must be a closed rectangle, circle, or polygon with at least 3 points")
        }

        let length: Double
        switch parameters.termination {
        case .blind(let d): length = d
        case .symmetric(let d): length = d
        case .throughAll: length = 1.0 // caller (FeatureOperations) resolves throughAll to a concrete length before reaching the kernel for `.new`
        case .upToNext, .upToFace:
            throw GeometryKernelError.unsupportedOperation("Extrude termination upToNext/upToFace")
        }
        guard length > 0 else { throw GeometryKernelError.invalidProfile("Extrude distance must be positive") }

        let mesh = GeometryBuilder.prism(outline: pts, height: length, centered: isSymmetric(parameters.termination))
        let newSolid = Solid(mesh: mesh, kind: .prism(profile: profile, axis: SIMD3<Float>(0, 0, 1), length: length))

        switch parameters.resultType {
        case .new:
            return newSolid
        case .add(let targetID):
            guard let target = bodies[targetID] else { throw GeometryKernelError.bodyNotFound }
            return try boolean(.union, target, newSolid)
        case .remove(let targetID):
            guard let target = bodies[targetID] else { throw GeometryKernelError.bodyNotFound }
            return try cutThroughAllProfile(profile, from: target)
        case .intersect(let targetID):
            guard bodies[targetID] != nil else { throw GeometryKernelError.bodyNotFound }
            throw GeometryKernelError.unsupportedOperation("Extrude Intersect between arbitrary bodies")
        }
    }

    // MARK: - Revolve (not yet implemented — flagged clearly rather than faked)

    func revolve(_ profile: PlanarProfile, _ parameters: RevolveParameters) throws -> Solid {
        throw GeometryKernelError.unsupportedOperation("Revolve")
    }

    // MARK: - Boolean

    func boolean(_ operation: BooleanOperation, _ lhs: Solid, _ rhs: Solid) throws -> Solid {
        switch operation {
        case .union:
            // Reliable case only: bodies whose bounding boxes do not overlap combine as a single
            // multi-region mesh. Overlapping arbitrary unions need real B-rep and are not faked here.
            let lhsBox = lhs.mesh.boundingBox
            let rhsBox = rhs.mesh.boundingBox
            if boxesOverlap(lhsBox, rhsBox) {
                throw GeometryKernelError.unsupportedOperation("Union of overlapping arbitrary bodies")
            }
            var mesh = lhs.mesh
            let offset = UInt32(mesh.positions.count)
            mesh.positions.append(contentsOf: rhs.mesh.positions)
            mesh.normals.append(contentsOf: rhs.mesh.normals)
            mesh.indices.append(contentsOf: rhs.mesh.indices.map { $0 + offset })
            return Solid(mesh: mesh, kind: .prism(profile: .polygon(points: []), axis: .init(0, 0, 1), length: 0))
        case .subtract:
            switch (lhs.kind, rhs.kind) {
            case (.prism(let base, _, let len), .primitiveCylinder(let r, _)):
                let hole = HoleDefinition(center: .zero, diameter: r * 2, type: .simple, throughAll: true)
                _ = len
                return try applyHoles([hole], base: base, length: len, existing: lhs)
            default:
                throw GeometryKernelError.unsupportedOperation("Boolean subtract for this body combination")
            }
        case .intersect:
            throw GeometryKernelError.unsupportedOperation("Boolean intersect")
        }
    }

    // MARK: - Hole

    func createHole(_ definition: HoleDefinition, in solid: Solid) throws -> Solid {
        guard definition.throughAll else {
            throw GeometryKernelError.unsupportedOperation("Blind (non-through) holes")
        }
        switch solid.kind {
        case .prism(let profile, _, let length):
            return try applyHoles([definition], base: profile, length: length, existing: solid)
        case .prismWithHoles(let base, _, let length, let existingHoles):
            return try applyHoles(existingHoles + [definition], base: base, length: length, existing: solid)
        case .primitiveBox(let w, let h, let d):
            let profile = PlanarProfile.rectangle(width: w, height: d)
            return try applyHoles([definition], base: profile, length: h, existing: solid)
        default:
            throw GeometryKernelError.unsupportedOperation("Hole on non-prismatic body")
        }
    }

    // MARK: - Not-yet-implemented refinement features (explicit, not faked)

    func fillet(_ definition: FilletDefinition, in solid: Solid) throws -> Solid {
        throw GeometryKernelError.unsupportedOperation("Fillet")
    }
    func chamfer(_ definition: ChamferDefinition, in solid: Solid) throws -> Solid {
        throw GeometryKernelError.unsupportedOperation("Chamfer")
    }
    func shell(_ definition: ShellDefinition, in solid: Solid) throws -> Solid {
        throw GeometryKernelError.unsupportedOperation("Shell")
    }

    func tessellate(_ solid: Solid) throws -> RenderMesh {
        solid.mesh
    }

    // MARK: - Internal helpers

    private func isSymmetric(_ t: ExtrudeTermination) -> Bool {
        if case .symmetric = t { return true }
        return false
    }

    private func normalizedPolygon(_ profile: PlanarProfile) -> PlanarProfile {
        switch profile {
        case .rectangle(let w, let h):
            let pts: [SIMD2<Double>] = [
                .init(-w / 2, -h / 2), .init(w / 2, -h / 2), .init(w / 2, h / 2), .init(-w / 2, h / 2)
            ]
            return .polygon(points: pts)
        case .circle(let r):
            let segments = 48
            var pts: [SIMD2<Double>] = []
            for i in 0..<segments {
                let a = Double(i) / Double(segments) * 2 * .pi
                pts.append(.init(cos(a) * r, sin(a) * r))
            }
            return .polygon(points: pts)
        case .polygon(let pts):
            return .polygon(points: pts)
        }
    }

    private func boxesOverlap(_ a: (min: SIMD3<Float>, max: SIMD3<Float>), _ b: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Bool {
        for i in 0..<3 {
            if a.max[i] < b.min[i] || b.max[i] < a.min[i] { return false }
        }
        return true
    }

    private func cutThroughAllProfile(_ removeProfile: PlanarProfile, from target: Solid) throws -> Solid {
        switch target.kind {
        case .prism(let base, _, let length), .prismWithHoles(let base, _, let length, _):
            guard case .polygon(let holePts) = normalizedPolygon(removeProfile) else {
                throw GeometryKernelError.invalidProfile("Removed profile must resolve to a polygon")
            }
            let hole = HoleDefinition(center: .zero, diameter: boundingDiameter(holePts), type: .simple, throughAll: true)
            return try applyHoles([hole], base: base, length: length, existing: target, explicitHoleOutline: holePts)
        default:
            throw GeometryKernelError.unsupportedOperation("Extrude Remove on non-prismatic target")
        }
    }

    private func boundingDiameter(_ pts: [SIMD2<Double>]) -> Double {
        guard let first = pts.first else { return 0 }
        var lo = first, hi = first
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return simd_length(hi - lo)
    }

    private func applyHoles(_ holes: [HoleDefinition], base: PlanarProfile, length: Double, existing: Solid, explicitHoleOutline: [SIMD2<Double>]? = nil) throws -> Solid {
        guard case .polygon(let outerPts) = normalizedPolygon(base) else {
            throw GeometryKernelError.invalidProfile("Base profile must resolve to a polygon")
        }
        guard let firstHole = holes.last else { return existing }
        let holeOutline: [SIMD2<Double>]
        if let explicit = explicitHoleOutline {
            holeOutline = explicit.map { $0 + firstHole.center }
        } else {
            let segments = 32
            holeOutline = (0..<segments).map { i -> SIMD2<Double> in
                let a = Double(i) / Double(segments) * 2 * .pi
                let r = firstHole.diameter / 2
                return firstHole.center + SIMD2<Double>(cos(a) * r, sin(a) * r)
            }
        }
        let capPolygon = try PolygonBridge.bridgeHole(outer: outerPts, hole: holeOutline)
        let mesh = GeometryBuilder.prismWithBoreCap(capPolygon: capPolygon, outerOutline: outerPts, holeOutline: holeOutline, height: length)
        return Solid(id: existing.id, mesh: mesh, kind: .prismWithHoles(base: base, axis: .init(0, 0, 1), length: length, holes: holes))
    }
}
