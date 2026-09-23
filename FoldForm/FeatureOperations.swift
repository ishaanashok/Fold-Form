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
