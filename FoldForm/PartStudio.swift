import Foundation

/// A single Part Studio: reference geometry, sketches, feature history, named variables, and the
/// evaluated bodies produced by the last regeneration. Mirrors Onshape's Part Studio concept
/// (sketches and features create/modify parts in one shared workspace) per the plan.
final class PartStudio: ObservableObject {
    let id = UUID()
    var name: String
    let featureTree = FeatureTree()
    @Published var variables: [String: Double] = [:]
    @Published private(set) var bodiesByID: [UUID: Solid] = [:]
    @Published private(set) var lastRegenerationError: String?

    private let kernel: GeometryKernel = ProceduralGeometryKernel()

    init(name: String = "Part Studio 1") {
        self.name = name
    }

    var orderedBodyIDs: [UUID] {
        // Stable order: first-produced-first, based on feature tree order.
        var seen = Set<UUID>()
        var order: [UUID] = []
        for feature in featureTree.features {
            if let id = feature.resultBodyID, bodiesByID[id] != nil, !seen.contains(id) {
                seen.insert(id)
                order.append(id)
            }
        }
        return order
    }

    @discardableResult
    func regenerate() -> [UUID: Solid] {
        let bodies = featureTree.regenerateAll(kernel: kernel)
        bodiesByID = bodies
        lastRegenerationError = featureTree.features.compactMap {
            if case .failed(let message) = $0.regenerationState { return "\($0.name): \(message)" }
            return nil
        }.first
        return bodies
    }

    func body(_ id: UUID) -> Solid? { bodiesByID[id] }
}
