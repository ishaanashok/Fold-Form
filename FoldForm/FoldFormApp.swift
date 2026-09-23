import SwiftUI

@main
struct FoldFormApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Split arrangement: RealityKit viewport as primary, modeling/control panel as secondary,
/// per plan section 4 ("Use ArrangementView with a split arrangement when the API is available").
struct RootView: View {
    @StateObject private var appModel = AppModel()

    var body: some View {
        ArrangementView {
            RealityViewport()
        } secondary: {
            ControlPanelView()
        }
        .arrangementViewStyle(.split)
        .environmentObject(appModel)
        .bindHingeInput(appModel.hingeInput)
        .preferredColorScheme(.dark)
    }
}
