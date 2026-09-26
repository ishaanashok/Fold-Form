import Foundation
import Combine

enum FeatureRegenerationState: Equatable {
    case pending
    case success
    case failed(String)
    case suppressed
}

/// Everything a feature needs to regenerate itself: the sketches available in the Part Studio and
/// the bodies produced by features evaluated so far (in feature-tree order).
struct FeatureRegenerationContext {
    var sketchesByID: [UUID: Sketch]
    var bodiesByID: [UUID: Solid]
    let kernel: GeometryKernel
}

/// A single entry in the ordered feature tree. Reference type: the tree and the regeneration
/// pipeline mutate `regenerationState`/`resultBodyID` on the same instance every feature holds a
/// reference to (its own ID), matching the plan's requirement that a failed feature stays visible
/// in the tree with an explanatory error rather than being silently deleted.
protocol Feature: AnyObject {
    var id: UUID { get }
    var name: String { get set }
    var isVisible: Bool { get set }
    var isSuppressed: Bool { get set }
    var regenerationState: FeatureRegenerationState { get set }
    var resultBodyID: UUID? { get set }
    var kindLabel: String { get }
    func regenerate(_ context: inout FeatureRegenerationContext)
}

final class FeatureTree: ObservableObject {
    @Published private(set) var features: [any Feature] = []
    @Published private(set) var referencePlanes: [ReferenceGeometry] = ReferenceGeometry.standardSet()
    @Published private(set) var sketches: [Sketch] = []

    func addSketch(_ sketch: Sketch) {
        sketches.append(sketch)
    }

    func updateSketch(_ sketch: Sketch) {
        guard let idx = sketches.firstIndex(where: { $0.id == sketch.id }) else { return }
        sketches[idx] = sketch
    }

    @discardableResult
    func append(_ feature: any Feature) -> any Feature {
        features.append(feature)
        return feature
    }

    func restore(_ snapshot: [any Feature]) {
        features = snapshot
    }

    func remove(id: UUID) {
        features.removeAll { $0.id == id }
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let feature = features.first(where: { $0.id == id }) else { return }
        feature.name = trimmed
        objectWillChange.send()
    }

    func moveFeature(id: UUID, toIndex index: Int) {
        guard let from = features.firstIndex(where: { $0.id == id }) else { return }
        let feature = features.remove(at: from)
        features.insert(feature, at: min(index, features.count))
    }

    func feature(id: UUID) -> (any Feature)? {
        features.first { $0.id == id }
    }

    /// Evaluates every non-suppressed feature in order. A failed feature keeps its prior
    /// `resultBodyID` (if any) so downstream features and the viewport can still show something
    /// sensible, but its own state is `.failed` and it does not contribute a *new* body.
    @discardableResult
    func regenerateAll(kernel: GeometryKernel) -> [UUID: Solid] {
        objectWillChange.send()
        var context = FeatureRegenerationContext(sketchesByID: Dictionary(uniqueKeysWithValues: sketches.map { ($0.id, $0) }), bodiesByID: [:], kernel: kernel)
        for feature in features {
            if feature.isSuppressed {
                feature.regenerationState = .suppressed
                continue
            }
            feature.regenerate(&context)
        }
        return context.bodiesByID
    }

    /// Rolls the tree back so only features up to and including `index` are active for regeneration
    /// preview purposes; used by the feature-tree UI's rollback bar.
    func regenerate(upTo index: Int, kernel: GeometryKernel) -> [UUID: Solid] {
        objectWillChange.send()
        var context = FeatureRegenerationContext(sketchesByID: Dictionary(uniqueKeysWithValues: sketches.map { ($0.id, $0) }), bodiesByID: [:], kernel: kernel)
        for (i, feature) in features.enumerated() where i <= index {
            if feature.isSuppressed {
                feature.regenerationState = .suppressed
                continue
            }
            feature.regenerate(&context)
        }
        return context.bodiesByID
    }
}
