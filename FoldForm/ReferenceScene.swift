import RealityKit
import SwiftUI
import UIKit

/// Which of the reference planes and the origin are shown, and the light/dark look.
struct ReferenceVisibility: Equatable {
    static let defaultDarkMode = false
    var planesHidden = false
    /// Right/Left plane (normal along X).
    var showRightLeft = true
    /// Up/Down plane (normal along Y, the plane the plate lies in).
    var showUpDown = true
    /// Front/Back plane (normal along Z).
    var showFrontBack = true
    var originHidden = false
    /// The grid uses a contrast-adjusted neutral stroke for each appearance.
    var darkMode = Self.defaultDarkMode
}

/// Three mutually perpendicular open grids through the origin, and a dot at their crossing.
@MainActor
final class ReferenceScene {
    let root = Entity()
    private let rightLeft = Entity()
    private let upDown = Entity()
    private let frontBack = Entity()
    private let origin = Entity()

    static let planeSize: Float = 0.13
    private static let gridDivisions = 12
    private static let lineThickness: Float = 0.00010
    private var grids: [ModelEntity] = []
    private let originDot = ModelEntity(mesh: .generateSphere(radius: 0.0013))

    init() {
        rightLeft.addChild(plane())
        rightLeft.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        upDown.addChild(plane())
        frontBack.addChild(plane())
        frontBack.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        origin.addChild(originDot)
        for entity in [rightLeft, upDown, frontBack, origin] { root.addChild(entity) }
        apply(ReferenceVisibility())
    }

    func apply(_ visibility: ReferenceVisibility) {
        rightLeft.isEnabled = !visibility.planesHidden && visibility.showRightLeft
        upDown.isEnabled = !visibility.planesHidden && visibility.showUpDown
        frontBack.isEnabled = !visibility.planesHidden && visibility.showFrontBack
        origin.isEnabled = !visibility.originHidden
        let lineColor = UIColor(white: visibility.darkMode ? 0.44 : 0.78, alpha: 1)
        let dotColor = UIColor(white: visibility.darkMode ? 0.72 : 0.48, alpha: 1)
        for grid in grids { grid.model?.materials = [UnlitMaterial(color: lineColor)] }
        originDot.model?.materials = [UnlitMaterial(color: dotColor)]
    }

    /// A square wire grid in the local XZ plane, with open cells and no surface fill.
    static func gridMesh() -> RenderMesh {
        let half = planeSize / 2
        let step = planeSize / Float(gridDivisions)
        let xLine = GeometryBuilder.box(width: Double(planeSize), height: Double(lineThickness), depth: Double(lineThickness))
        let zLine = GeometryBuilder.box(width: Double(lineThickness), height: Double(lineThickness), depth: Double(planeSize))
        var lines: [RenderMesh] = []
        for index in 0...gridDivisions {
            let offset = -half + Float(index) * step
            lines.append(xLine.translated(by: SIMD3(0, 0, offset)))
            lines.append(zLine.translated(by: SIMD3(offset, 0, 0)))
        }
        return RenderMesh.merged(lines)
    }

    private func plane() -> Entity {
        let group = Entity()
        let mesh = Self.gridMesh()
        var descriptor = MeshDescriptor(name: "ReferenceGrid")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return group }
        let grid = ModelEntity(mesh: resource)
        grids.append(grid)
        group.addChild(grid)
        return group
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
