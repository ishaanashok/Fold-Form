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
        // Give the 3D viewport more of the width in side-by-side (landscape/spanning) layouts, so
        // the control column starts further right and the model has more room to be centered and
        // legible, per feedback that controls were crowding the model.
        .splitArrangementLayoutRatio(idealHorizontal: 0.62)
        .environmentObject(appModel)
        .bindHingeInput(appModel.hingeInput)
        .preferredColorScheme(.dark)
    }
}
