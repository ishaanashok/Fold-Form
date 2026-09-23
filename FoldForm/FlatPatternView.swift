import SwiftUI

/// 2D flat-pattern view driven by the same published angle/calculator result as the 3D bend
/// (plan section 6: "The 2D view and 3D view must be driven by the same published angle and
/// calculator result. No duplicated angle state.").
struct FlatPatternView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Flat Pattern").font(.headline)
            Canvas { context, size in
                let scale: CGFloat = size.width / max(CGFloat(appModel.sheetMetalResult.flatLength) * 1.4, 1)
                let midY = size.height / 2
                let leg1 = CGFloat(appModel.legOneLength) * scale
                let bendZoneWidth = CGFloat(appModel.sheetMetalResult.bendAllowance) * scale
                let leg2 = CGFloat(appModel.legTwoLength) * scale
                let startX: CGFloat = 10

                var path = Path()
                path.move(to: .init(x: startX, y: midY))
                path.addLine(to: .init(x: startX + leg1, y: midY))
                path.addLine(to: .init(x: startX + leg1 + bendZoneWidth, y: midY))
                path.addLine(to: .init(x: startX + leg1 + bendZoneWidth + leg2, y: midY))
                context.stroke(path, with: .color(.white), lineWidth: 4)

                let bendRect = CGRect(x: startX + leg1, y: midY - 8, width: max(bendZoneWidth, 1), height: 16)
                context.fill(Path(bendRect), with: .color(.yellow.opacity(0.6)))

                context.draw(Text("θ = \(Int(appModel.hingeInput.hingeAngleDegrees))°").font(.caption2), at: .init(x: startX, y: midY - 24))
                context.draw(Text("BA \(String(format: "%.1f", appModel.sheetMetalResult.bendAllowance))").font(.caption2), at: .init(x: startX + leg1, y: midY + 20))
                context.draw(Text("Flat length \(String(format: "%.1f", appModel.sheetMetalResult.flatLength))").font(.caption2), at: .init(x: startX, y: midY + 36))
            }
            .frame(height: 90)
            .background(Color.black.opacity(0.85))
        }
    }
}
