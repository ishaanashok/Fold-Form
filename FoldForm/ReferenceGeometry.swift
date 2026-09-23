import Foundation
import simd

/// The three standard reference planes plus the origin, always present in a PartStudio.
enum StandardPlane: String, CaseIterable, Identifiable, Codable {
    case front, top, right
    var id: String { rawValue }

    /// Orientation of the plane in the Part Studio's local space, matching the bend-axis
    /// convention (X = fold distance, Y = thickness, Z = crease length) documented in GeometryBuilder.
    var normal: SIMD3<Float> {
        switch self {
        case .front: return .init(0, 0, 1)
        case .top: return .init(0, 1, 0)
        case .right: return .init(1, 0, 0)
        }
    }
}

struct ReferenceGeometry: Identifiable, Equatable {
    let id: UUID
    var name: String
    var plane: StandardPlane

    init(id: UUID = UUID(), name: String, plane: StandardPlane) {
        self.id = id
        self.name = name
        self.plane = plane
    }

    static func standardSet() -> [ReferenceGeometry] {
        StandardPlane.allCases.map { ReferenceGeometry(name: $0.rawValue.capitalized, plane: $0) }
    }
}
