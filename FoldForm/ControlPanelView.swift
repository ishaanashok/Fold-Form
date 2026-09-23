import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        GeometryReader { proxy in
            let divisionInsets = creaseAvoidingPadding(proxy)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("FoldForm").font(.title2.bold())

                    Picker("Workbench", selection: $appModel.activeWorkbench) {
                        ForEach(Workbench.allCases) { wb in Text(wb.rawValue).tag(wb) }
                    }
                    .pickerStyle(.segmented)

                    if appModel.isSketchEditing, let sketchID = appModel.activeSketchID {
                        SketchEditorView(sketchID: sketchID)
                    } else {
                        ModelingToolbarView()

                        Text("\(Int(appModel.hingeInput.hingeAngleDegrees))°")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()

                        if appModel.hingeInput.isUsingSimulatorFallback {
                            VStack(alignment: .leading) {
                                Text("Simulator angle (no physical hinge detected)").font(.caption2)
                                Slider(value: Binding(
                                    get: { appModel.hingeInput.simulatorAngleRadians },
                                    set: { appModel.hingeInput.simulatorAngleRadians = $0 }
                                ), in: 0...(.pi / 2))
                            }
                        }

                        Picker("Profile", selection: $appModel.selectedProfile) {
                            ForEach(PartProfileKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }
                        .pickerStyle(.menu)

                        if appModel.activeWorkbench == .sheetMetal {
                            ParameterEditorView()
                            FlatPatternView()
                        }

                        legend

                        Text("Feature Tree").font(.subheadline.bold())
                        FeatureTreeView(partStudio: appModel.document.partStudio)

                        Button("Start Demo") { appModel.startDemo() }
                            .buttonStyle(.borderedProminent)

                        if appModel.showOnboarding {
                            Text("Fold the phone to bend the part. The crease is the bend axis.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { appModel.showOnboarding = false }
                                }
                        }
                    }
                }
                .padding()
                .padding(divisionInsets)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: .yellow, label: "Bend axis")
            legendItem(color: .red, label: "Collision")
            legendItem(color: .orange, label: "Bend limit")
        }
        .font(.caption2)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    /// Keeps controls clear of the physical division region using the real `reservedRegions` API
    /// (plan section 4: "Use reservedRegions(kind: .division) to keep important controls and labels
    /// clear of the physical crease... Do not branch layout based on hinge.angle").
    private func creaseAvoidingPadding(_ proxy: GeometryProxy) -> EdgeInsets {
        let regions = proxy.reservedRegions(kind: .division)
        guard let region = regions.first(where: { $0.isActive }) else { return EdgeInsets() }
        return region.margins
    }
}
