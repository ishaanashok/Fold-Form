import Foundation
import simd

/// How a part looks in the viewport. Colour lives on the document body, not the mesh, so it survives
/// touch ups and comes back with undo.
struct PartStyle: Equatable {
    var name: String
    var rgb: SIMD3<Float>
    var roughness: Float
    var isMetallic: Bool
}

enum Palette {
    static let styles: [String: PartStyle] = [
        "oak": PartStyle(name: "oak", rgb: [0.78, 0.60, 0.38], roughness: 0.75, isMetallic: false),
        "walnut": PartStyle(name: "walnut", rgb: [0.36, 0.23, 0.14], roughness: 0.7, isMetallic: false),
        "pine": PartStyle(name: "pine", rgb: [0.88, 0.74, 0.50], roughness: 0.8, isMetallic: false),
        "cherry": PartStyle(name: "cherry", rgb: [0.60, 0.27, 0.18], roughness: 0.7, isMetallic: false),
        "white": PartStyle(name: "white", rgb: [0.93, 0.93, 0.91], roughness: 0.6, isMetallic: false),
        "black": PartStyle(name: "black", rgb: [0.10, 0.10, 0.11], roughness: 0.5, isMetallic: false),
        "grey": PartStyle(name: "grey", rgb: [0.55, 0.57, 0.60], roughness: 0.7, isMetallic: false),
        "steel": PartStyle(name: "steel", rgb: [0.72, 0.74, 0.77], roughness: 0.35, isMetallic: true),
        "blue": PartStyle(name: "blue", rgb: [0.16, 0.42, 0.95], roughness: 1, isMetallic: false),
        "red": PartStyle(name: "red", rgb: [0.80, 0.18, 0.16], roughness: 0.7, isMetallic: false),
        "green": PartStyle(name: "green", rgb: [0.22, 0.55, 0.32], roughness: 0.7, isMetallic: false),
    ]

    static var names: [String] { styles.keys.sorted() }

    static func style(_ name: String) -> PartStyle? { styles[name.lowercased()] }
}
