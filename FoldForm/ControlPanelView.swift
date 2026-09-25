import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject var appModel: AppModel
    var onStartDemo: () -> Void = {}
    var onTool: ((ModelingTool) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let divisionInsets = creaseAvoidingPadding(proxy)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FoldForm").font(.title2.bold())
                        Text("Part Studio 1").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 10)

                workbenchBar
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                Divider().opacity(0.35)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {

                        if appModel.isSketchEditing, let sketchID = appModel.activeSketchID {
                            SketchEditorView(sketchID: sketchID)
                        } else {
                            ModelingToolbarView(onTool: onTool)

                            Text(appModel.lastOperationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("\(Int(appModel.hingeInput.bendAngleDegrees.rounded()))°")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()

                            if appModel.hingeInput.isUsingSimulatorFallback {
                                VStack(alignment: .leading) {
                                    Text("Simulator bend (no physical hinge detected)").font(.caption2)
                                    Slider(value: Binding(
                                        get: { appModel.hingeInput.simulatorBendRadians },
                                        set: { appModel.hingeInput.simulatorBendRadians = $0 }
                                    ), in: 0...(.pi))
                                }
                            }

                            Picker("Profile", selection: Binding(
                                get: { appModel.selectedProfile },
                                set: { appModel.selectProfile($0) }
                            )) {
                                ForEach(PartProfileKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                            }
                            .pickerStyle(.menu)

                            if appModel.activeWorkbench == .sheetMetal {
                                ParameterEditorView()
                                FlatPatternView()
                            }

                            if appModel.activeWorkbench == .inspect {
                                InspectionPanelView()
                            }

                            Text("Feature Tree").font(.subheadline.bold())
                            FeatureTreeView(featureTree: appModel.document.partStudio.featureTree)

                            Button("Start Demo") { onStartDemo() }
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
    }

    private var workbenchBar: some View {
        HStack(spacing: 4) {
            ForEach(Workbench.allCases) { workbench in
                Button {
                    appModel.activeWorkbench = workbench
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: workbench.systemImage)
                            .font(.caption)
                        Text(workbench.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .foregroundStyle(appModel.activeWorkbench == workbench ? .primary : .secondary)
                    .background(
                        appModel.activeWorkbench == workbench ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Keeps controls clear of the physical division region using the real `reservedRegions` API
    /// (plan section 4: "Use reservedRegions(kind: .division) to keep important controls and labels
    /// clear of the physical crease... Do not branch layout based on hinge.angle").
    private func creaseAvoidingPadding(_ proxy: GeometryProxy) -> EdgeInsets {
        let regions = proxy.reservedRegions(kind: .division)
        // The region itself is opaque by design. Its presence is enough to reserve a comfortable
        // gutter around the physical division while keeping layout independent of hinge angle.
        guard !regions.isEmpty else { return EdgeInsets() }
        return EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    }
}

private struct InspectionPanelView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspection").font(.headline)
            inspectionRow("Profile", appModel.selectedProfile.rawValue)
            inspectionRow("Bodies", String(appModel.document.partStudio.bodiesByID.count))
            inspectionRow("Features", String(appModel.document.partStudio.featureTree.features.count))
            inspectionRow("Hinge source", appModel.hingeInput.isUsingSimulatorFallback ? "Simulator fallback" : "Device hinge")
            inspectionRow("Hinge angle", appModel.hingeInput.rawHingeRadians.map { "\(Int(($0 * 180 / .pi).rounded()))° (180° = flat)" } ?? "—")
            inspectionRow("Bend", "\(Int(appModel.hingeInput.bendAngleDegrees.rounded()))°")
            inspectionRow("Demo state", appModel.demo.state.rawValue)
            inspectionRow("Bend limit", String(Int(appModel.demoBendLimitRadians * 180 / .pi)) + "°")
            if let error = appModel.document.partStudio.lastRegenerationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Feature history regenerated successfully", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func inspectionRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
        .font(.caption)
    }
}
