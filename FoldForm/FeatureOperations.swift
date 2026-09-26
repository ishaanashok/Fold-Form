import Foundation

/// Marks a sketch as consumed at this point in the feature tree. Carries no geometry of its own —
/// the sketch's resolved profile is read directly by downstream Extrude/Hole/Revolve features.
final class SketchTreeFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    let sketchID: UUID
    var kindLabel: String { "Sketch" }

    init(name: String, sketchID: UUID) {
        self.name = name
        self.sketchID = sketchID
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        if context.sketchesByID[sketchID] != nil {
            regenerationState = .success
        } else {
            regenerationState = .failed("Sketch reference lost")
        }
    }
}

final class ExtrudeFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    var kindLabel: String { "Extrude" }

    var sketchID: UUID
    var parameters: ExtrudeParameters
    /// Resolved concrete length for `.throughAll`, computed once at creation from the current
    /// geometry so regeneration stays deterministic without re-deriving scene bounds every time.
    var throughAllLength: Double
    /// Stable body identity for `.new` results: the kernel mints a fresh `Solid.id` on every call,
    /// but downstream features (Hole, Boolean) hold a `targetBodyID` that must stay valid across
    /// repeated regenerations, so this feature always republishes its body under the same ID.
    private let stableNewBodyID = UUID()

    init(name: String, sketchID: UUID, parameters: ExtrudeParameters, throughAllLength: Double = 0.5) {
        self.name = name
        self.sketchID = sketchID
        self.parameters = parameters
        self.throughAllLength = throughAllLength
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        guard let sketch = context.sketchesByID[sketchID] else {
            regenerationState = .failed("Reference lost: source sketch no longer exists")
            return
        }
        do {
            let profile = try sketch.resolveClosedProfile()
            var resolvedParams = parameters
            if case .throughAll = parameters.termination {
                resolvedParams.termination = .blind(distance: throughAllLength)
            }
            let solid = try context.kernel.extrude(profile, resolvedParams, into: context.bodiesByID)
            let bodyID: UUID
            switch parameters.resultType {
            case .new: bodyID = stableNewBodyID
            case .add(let target), .remove(let target), .intersect(let target): bodyID = target
            }
            context.bodiesByID[bodyID] = Solid(id: bodyID, mesh: solid.mesh, kind: solid.kind)
            resultBodyID = bodyID
            regenerationState = .success
        } catch {
            regenerationState = .failed(error.localizedDescription)
        }
    }
}

final class HoleFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    var kindLabel: String { "Hole" }

    var targetBodyID: UUID
    var definition: HoleDefinition

    init(name: String, targetBodyID: UUID, definition: HoleDefinition) {
        self.name = name
        self.targetBodyID = targetBodyID
        self.definition = definition
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        guard let target = context.bodiesByID[targetBodyID] else {
            regenerationState = .failed("Reference lost: target body no longer exists")
            return
        }
        do {
            let result = try context.kernel.createHole(definition, in: target)
            context.bodiesByID[targetBodyID] = result
            resultBodyID = targetBodyID
            regenerationState = .success
        } catch {
            regenerationState = .failed(error.localizedDescription)
        }
    }
}

final class BooleanFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    var kindLabel: String { "Boolean" }

    var operation: BooleanOperation
    var lhsBodyID: UUID
    var rhsBodyID: UUID

    init(name: String, operation: BooleanOperation, lhsBodyID: UUID, rhsBodyID: UUID) {
        self.name = name
        self.operation = operation
        self.lhsBodyID = lhsBodyID
        self.rhsBodyID = rhsBodyID
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        guard let lhs = context.bodiesByID[lhsBodyID], let rhs = context.bodiesByID[rhsBodyID] else {
            regenerationState = .failed("Reference lost: input body no longer exists")
            return
        }
        do {
            let result = try context.kernel.boolean(operation, lhs, rhs)
            context.bodiesByID[lhsBodyID] = Solid(id: lhsBodyID, mesh: result.mesh, kind: result.kind)
            context.bodiesByID.removeValue(forKey: rhsBodyID)
            resultBodyID = lhsBodyID
            regenerationState = .success
        } catch {
            regenerationState = .failed(error.localizedDescription)
        }
    }
}

/// Shared base for refinement/transform features not yet backed by real geometry
/// (Fillet, Chamfer, Shell, Draft, Pattern, Mirror, Transform, Delete Face). Each preserves its
/// parameters and reports a clear, typed error per plan section 13 ("do not fake a successful
/// feature by silently leaving the body unchanged").
final class UnimplementedFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    let label: String
    var kindLabel: String { label }
    let targetBodyID: UUID?

    init(name: String, label: String, targetBodyID: UUID? = nil) {
        self.name = name
        self.label = label
        self.targetBodyID = targetBodyID
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        resultBodyID = targetBodyID
        regenerationState = .failed("\(label) is not yet implemented in this geometry kernel")
    }
}

/// A bridge for the direct viewport sketch workflow. It keeps the generated solid in the same
/// Part Studio history that the control panel displays, instead of leaving it only in FoldSession.
final class ViewportSolidFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    var kindLabel: String { "Extrude" }

    private let mesh: RenderMesh
    private let stableBodyID = UUID()

    init(name: String, mesh: RenderMesh) {
        self.name = name
        self.mesh = mesh
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        guard !mesh.positions.isEmpty else {
            regenerationState = .failed("Viewport extrusion produced no geometry")
            return
        }
        let box = mesh.boundingBox
        context.bodiesByID[stableBodyID] = Solid(
            id: stableBodyID,
            mesh: mesh,
            kind: .primitiveBox(
                width: Double(box.max.x - box.min.x),
                height: Double(box.max.y - box.min.y),
                depth: Double(box.max.z - box.min.z)
            )
        )
        resultBodyID = stableBodyID
        regenerationState = .success
    }
}

/// A removal drawn in the viewport: the cutter solid is subtracted from every body it touches.
final class ViewportCutFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID? = nil
    var kindLabel: String { "Cut" }

    private let cutter: RenderMesh

    init(name: String, cutter: RenderMesh) {
        self.name = name
        self.cutter = cutter
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        guard !cutter.positions.isEmpty else {
            regenerationState = .failed("Viewport cut produced no geometry")
            return
        }
        let cut = cutter.boundingBox
        for (id, solid) in context.bodiesByID {
            let box = solid.mesh.boundingBox
            guard box.min.x < cut.max.x, box.max.x > cut.min.x,
                  box.min.y < cut.max.y, box.max.y > cut.min.y,
                  box.min.z < cut.max.z, box.max.z > cut.min.z else { continue }
            let result = MeshCSG.subtract(solid.mesh, cutter)
            if result.indices.isEmpty {
                context.bodiesByID[id] = nil
            } else {
                context.bodiesByID[id]?.mesh = result
            }
        }
        regenerationState = .success
    }
}

/// A touch-up pass: the smoothed mesh replaces one body's mesh wherever this sits in the tree.
final class ViewportTouchUpFeature: Feature {
    let id = UUID()
    var name: String
    var isVisible = true
    var isSuppressed = false
    var regenerationState: FeatureRegenerationState = .pending
    var resultBodyID: UUID?
    var kindLabel: String { "Touch up" }

    private let targetBodyID: UUID
    private let mesh: RenderMesh

    init(name: String, targetBodyID: UUID, mesh: RenderMesh) {
        self.name = name
        self.targetBodyID = targetBodyID
        self.mesh = mesh
    }

    func regenerate(_ context: inout FeatureRegenerationContext) {
        // A body that has since been deleted simply has nothing left to touch up.
        guard context.bodiesByID[targetBodyID] != nil else {
            resultBodyID = nil
            regenerationState = .success
            return
        }
        context.bodiesByID[targetBodyID]?.mesh = mesh
        resultBodyID = targetBodyID
        regenerationState = .success
    }
}
