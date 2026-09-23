import SwiftUI

/// Compact CAD command bar inspired by Part Studio workflows: tools stay visible, the active
/// command is obvious, and unsupported kernel operations remain honest in the feature history.
struct ModelingToolbarView: View {
    @EnvironmentObject var appModel: AppModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Create").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("Part Studio tools").font(.caption2).foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(ModelingTool.allCases) { tool in
                    Button {
                        appModel.activate(tool)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                            Text(tool.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.bordered)
                    .tint(appModel.activeTool == tool ? .accentColor : .secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
