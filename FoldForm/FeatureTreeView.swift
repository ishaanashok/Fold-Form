import SwiftUI

struct FeatureTreeView: View {
    @EnvironmentObject var appModel: AppModel
    @ObservedObject var featureTree: FeatureTree
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.yellow)
                Text("Part Studio 1")
                    .font(.caption.bold())
                Spacer()
                Text("MODEL TREE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            ForEach(featureTree.referencePlanes) { plane in
                Label(plane.name, systemImage: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .padding(.vertical, 3)
            }
            ForEach(featureTree.features, id: \.id) { feature in
                HStack {
                    stateIcon(feature.regenerationState)
                    Image(systemName: featureIcon(feature))
                        .foregroundStyle(.secondary)
                    Text(feature.name)
                        .font(.caption)
                        .strikethrough(feature.isSuppressed)
                    Spacer()
                    Text(feature.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isSelected(feature.id) ? Color.accentColor.opacity(0.20) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onTapGesture {
                    if let bodyID = feature.resultBodyID {
                        appModel.selection.select(.body(bodyID))
                    }
                    appModel.selection.select(.feature(feature.id))
                }
                .contextMenu {
                    Button(feature.isSuppressed ? "Unsuppress" : "Suppress") {
                        feature.isSuppressed.toggle()
                        appModel.document.partStudio.regenerate()
                    }
                    Button("Rename") {
                        renameTarget = feature.id
                        renameText = feature.name
                    }
                    Button("Delete", role: .destructive) {
                        featureTree.remove(id: feature.id)
                        appModel.document.partStudio.regenerate()
                    }
                }
                if case .failed(let message) = feature.regenerationState {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .alert("Rename feature", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Feature name", text: $renameText)
            Button("Save") {
                if let renameTarget { featureTree.rename(id: renameTarget, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Names stay in the editable feature history.")
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: FeatureRegenerationState) -> some View {
        switch state {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .suppressed: Image(systemName: "eye.slash").foregroundStyle(.gray)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    private func isSelected(_ featureID: UUID) -> Bool {
        guard case .feature(let id) = appModel.selection.selection else { return false }
        return id == featureID
    }

    private func featureIcon(_ feature: any Feature) -> String {
        switch feature.kindLabel.lowercased() {
        case "sketch": return "pencil.and.outline"
        case "extrude": return "arrow.up.to.line"
        case "hole": return "circle.dotted"
        default: return "cube"
        }
    }
}
