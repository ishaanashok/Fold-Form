import SwiftUI

struct StatusBadgeView: View {
    @EnvironmentObject var appModel: AppModel

    private var label: String {
        if appModel.collision.maxBendReached { return "MAX BEND" }
        if appModel.collisionIsActive { return "COLLISION" }
        if appModel.hingeInput.hingeAngleDegrees > 1 { return "BENDING" }
        return "READY"
    }

    private var color: Color {
        if appModel.collision.maxBendReached { return .orange }
        if appModel.collisionIsActive { return .red }
        if appModel.hingeInput.hingeAngleDegrees > 1 { return .yellow }
        return .green
    }

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}
