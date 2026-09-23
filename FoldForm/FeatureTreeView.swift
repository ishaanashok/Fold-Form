import SwiftUI

struct FeatureTreeView: View {
    @EnvironmentObject var appModel: AppModel
    @ObservedObject var featureTree: FeatureTree
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(featureTree.referencePlanes) { plane in
                Label(plane.name, systemImage: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(featureTree.features, id: \.id) { feature in
                HStack {
                    stateIcon(feature.regenerationState)
                    Text(feature.name)
                        .font(.caption)
                        .strikethrough(feature.isSuppressed)
                    Spacer()
                    Text(feature.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
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
}
