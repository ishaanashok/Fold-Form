import SwiftUI

struct ModelingToolbarView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ModelingTool.allCases) { tool in
                    Button(tool.rawValue) {
                        appModel.activeTool = tool
                        if tool == .sketch { appModel.beginSketching() }
                    }
                    .buttonStyle(.bordered)
                    .tint(appModel.activeTool == tool ? .accentColor : .gray)
                }
            }
        }
    }
}
