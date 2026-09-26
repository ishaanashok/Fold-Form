import RealityKit
import SwiftUI
import UIKit

/// Which of the reference planes and the origin are shown, and the light/dark look.
struct ReferenceVisibility: Equatable {
    var planesHidden = false
    /// Right/Left plane (normal along X).
    var showRightLeft = true
    /// Up/Down plane (normal along Y, the plane the plate lies in).
    var showUpDown = true
    /// Front/Back plane (normal along Z).
    var showFrontBack = true
    var originHidden = false
    /// White planes on the dark background, dark planes on the light one, so they always contrast.
    var darkMode = true
}

/// The default planes and the origin, as in a Part Studio: three mutually perpendicular translucent
/// planes through the origin, and a dot at their crossing.
@MainActor
final class ReferenceScene {
    let root = Entity()
    private let rightLeft = Entity()
    private let upDown = Entity()
    private let frontBack = Entity()
    private let origin = Entity()

    static let planeSize: Float = 0.13
    private var fills: [ModelEntity] = []
    private var edges: [ModelEntity] = []

    init() {
        rightLeft.addChild(plane())
        rightLeft.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        upDown.addChild(plane())
        frontBack.addChild(plane())
        frontBack.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        Self.buildOrigin(into: origin)
        for entity in [rightLeft, upDown, frontBack, origin] { root.addChild(entity) }
    }

    func apply(_ visibility: ReferenceVisibility) {
        rightLeft.isEnabled = !visibility.planesHidden && visibility.showRightLeft
        upDown.isEnabled = !visibility.planesHidden && visibility.showUpDown
        frontBack.isEnabled = !visibility.planesHidden && visibility.showFrontBack
        origin.isEnabled = !visibility.originHidden
        let fillColor = UIColor(white: visibility.darkMode ? 0.2 : 0.86, alpha: 1)
        let edgeColor = UIColor(white: visibility.darkMode ? 0.36 : 0.66, alpha: 1)
        var fill = UnlitMaterial(color: fillColor)
        fill.blending = .transparent(opacity: .init(floatLiteral: 0.78))
        fill.faceCulling = .none
        for quad in fills { quad.model?.materials = [fill] }
        for bar in edges { bar.model?.materials = [UnlitMaterial(color: edgeColor)] }
    }

    /// A square in the local XZ plane (normal +Y) with a see-through fill and a solid outline;
    /// colours are set in `apply`.
    private func plane() -> Entity {
        let group = Entity()
        let quad = ModelEntity(mesh: .generatePlane(width: Self.planeSize, depth: Self.planeSize))
        fills.append(quad)
        group.addChild(quad)
        let half = Self.planeSize / 2, t: Float = 0.0005, size = Self.planeSize
        let bars: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(size, t, t), SIMD3(0, 0, half)),
            (SIMD3(size, t, t), SIMD3(0, 0, -half)),
            (SIMD3(t, t, size), SIMD3(half, 0, 0)),
            (SIMD3(t, t, size), SIMD3(-half, 0, 0)),
        ]
        for (barSize, position) in bars {
            let bar = ModelEntity(mesh: .generateBox(size: barSize))
            bar.position = position
            edges.append(bar)
            group.addChild(bar)
        }
        return group
    }

    private static func buildOrigin(into entity: Entity) {
        let dot = ModelEntity(
            mesh: .generateSphere(radius: 0.003),
            materials: [UnlitMaterial(color: UIColor(red: 1.0, green: 0.8, blue: 0.1, alpha: 1))]
        )
        entity.addChild(dot)
    }
}

/// The waffle menu: view toggles only.
struct ViewOptionsView: View {
    @Binding var reference: ReferenceVisibility
    @Binding var darkMode: Bool
    @Binding var showDimensions: Bool
    @Binding var unit: DimensionUnit

    var body: some View {
        NavigationStack {
            List {
                Section("Planes") {
                    Toggle("Hide planes", isOn: $reference.planesHidden)
                        .accessibilityIdentifier("toggleHidePlanes")
                    Toggle("Right / Left plane", isOn: $reference.showRightLeft)
                        .accessibilityIdentifier("toggleRightLeft")
                        .disabled(reference.planesHidden)
                    Toggle("Up / Down plane", isOn: $reference.showUpDown)
                        .accessibilityIdentifier("toggleUpDown")
                        .disabled(reference.planesHidden)
                    Toggle("Front / Back plane", isOn: $reference.showFrontBack)
                        .accessibilityIdentifier("toggleFrontBack")
                        .disabled(reference.planesHidden)
                }
                Section("Origin") {
                    Toggle("Hide origin", isOn: $reference.originHidden)
                        .accessibilityIdentifier("toggleHideOrigin")
                }
                Section("Dimensions") {
                    Toggle("Show dimensions", isOn: $showDimensions)
                        .accessibilityIdentifier("toggleDimensions")
                    Picker("Units", selection: $unit) {
                        ForEach(DimensionUnit.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("dimensionUnitPicker")
                    .disabled(!showDimensions)
                }
                Section("Appearance") {
                    Toggle("Dark mode", isOn: $darkMode)
                        .accessibilityIdentifier("toggleDarkMode")
                }
            }
            .navigationTitle("View")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
