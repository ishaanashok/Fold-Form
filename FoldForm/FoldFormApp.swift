import SwiftUI

@main
struct FoldFormApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Full-bleed 3D viewport spanning the entire window (both panels across the physical crease),
/// the way a modeling tool's canvas fills the screen. Modeling tools, the feature tree, and sheet
/// metal/inspection panels are not permanently docked; they live behind a single waffle-menu
/// button and open as a sheet, so the model itself has the whole screen instead of sharing it with
/// a docked control column.
struct RootView: View {
    @StateObject private var appModel = AppModel()
    @State private var showTools = false

    var body: some View {
        ZStack {
            RealityViewport()

            GeometryReader { proxy in
                let insets = creaseAvoidingPadding(proxy)
                VStack {
                    HStack {
                        waffleButton
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        hudPill
                    }
                }
                .padding(insets)
                .padding(16)
            }
        }
        .environmentObject(appModel)
        .bindHingeInput(appModel.hingeInput)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTools) {
            ControlPanelView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appModel)
        }
    }

    private var waffleButton: some View {
        Button {
            showTools = true
        } label: {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// The one persistent piece of HUD: current bend angle plus a one-word status, small enough to
    /// stay out of the way of the model itself (plan's "large angle readout" now lives here, tucked
    /// into a corner instead of a whole docked panel).
    private var hudPill: some View {
        HStack(spacing: 6) {
            Text("\(Int(appModel.hingeInput.hingeAngleDegrees))°")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(hudStatusWord)
                .font(.caption2.bold())
                .foregroundStyle(hudStatusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hudStatusWord: String {
        if appModel.collision.maxBendReached { return "LIMIT" }
        if appModel.collisionIsActive { return "HIT" }
        if appModel.hingeInput.hingeAngleDegrees > 1 { return "BENDING" }
        return "READY"
    }

    private var hudStatusColor: Color {
        if appModel.collision.maxBendReached { return .orange }
        if appModel.collisionIsActive { return .red }
        if appModel.hingeInput.hingeAngleDegrees > 1 { return .yellow }
        return .green
    }

    /// Keeps the waffle button and HUD pill clear of the physical division region (plan section 4),
    /// without constraining the 3D content itself, which is free to span both panels.
    private func creaseAvoidingPadding(_ proxy: GeometryProxy) -> EdgeInsets {
        let regions = proxy.reservedRegions(kind: .division)
        guard !regions.isEmpty else { return EdgeInsets() }
        return EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    }
}
