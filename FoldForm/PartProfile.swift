import Foundation
import simd

/// Quick-start primitive profiles shown in the Profile/primitive picker (plan section 4).
/// These are convenience starting geometry, not the long-term modeling representation — the user
/// can switch into Model/Sketch mode and keep editing the same document (see CADDocument.swift).
enum PartProfileKind: String, CaseIterable, Identifiable {
    case beam = "Beam"
    case iBeam = "I-beam"
    case sheetPlate = "Sheet plate"
    case box = "Box"
    case cylinder = "Cylinder"
    var id: String { rawValue }
}

enum PartProfileFactory {
    /// All dimensions in meters (RealityKit's native unit).
    static func makeSolid(_ kind: PartProfileKind, length: Double = 0.16) -> Solid {
        let kernel = ProceduralGeometryKernel()
        switch kind {
        case .beam:
            return (try? kernel.makePrimitive(.box(width: 0.02, height: 0.02, depth: length))) ?? .init(mesh: .empty, kind: .primitiveBox(width: 0, height: 0, depth: 0))
        case .iBeam:
            // Simplified as a box until a compound-profile extrude is supported by the kernel.
            return (try? kernel.makePrimitive(.box(width: 0.03, height: 0.015, depth: length))) ?? .init(mesh: .empty, kind: .primitiveBox(width: 0, height: 0, depth: 0))
        case .sheetPlate:
            return (try? kernel.makePrimitive(.box(width: 0.16, height: 0.003, depth: length))) ?? .init(mesh: .empty, kind: .primitiveBox(width: 0, height: 0, depth: 0))
        case .box:
            return (try? kernel.makePrimitive(.box(width: 0.05, height: 0.05, depth: length))) ?? .init(mesh: .empty, kind: .primitiveBox(width: 0, height: 0, depth: 0))
        case .cylinder:
            return (try? kernel.makePrimitive(.cylinder(radius: 0.02, height: length))) ?? .init(mesh: .empty, kind: .primitiveCylinder(radius: 0, height: 0))
        }
    }
}
