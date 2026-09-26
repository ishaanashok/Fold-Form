import Foundation
import simd

extension RenderMesh {
    /// The mesh turned by `rotation` about `pivot`. A rotation keeps triangle winding, so the
    /// indices are unchanged; normals turn with the points.
    func rotated(by rotation: simd_quatf, about pivot: SIMD3<Float>) -> RenderMesh {
        RenderMesh(
            positions: positions.map { pivot + rotation.act($0 - pivot) },
            normals: normals.map { rotation.act($0) },
            indices: indices
        )
    }
}
