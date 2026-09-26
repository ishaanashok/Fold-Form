import SwiftUI
import simd

struct SketchCanvas: View {
    @Binding var drawing: SketchDrawing
    @State private var currentStroke: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for line in drawing.polylines where !line.isEmpty {
                    var path = Path()
                    path.move(to: CGPoint(x: CGFloat(line[0].x) * size.width, y: CGFloat(line[0].y) * size.height))
                    for point in line.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height))
                    }
                    context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if !currentStroke.isEmpty {
                    var path = Path()
                    path.move(to: currentStroke[0])
                    for point in currentStroke.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let point = CGPoint(
                        x: min(max(value.location.x, 0), geometry.size.width),
                        y: min(max(value.location.y, 0), geometry.size.height)
                    )
                    if currentStroke.isEmpty || hypot(point.x - currentStroke.last!.x, point.y - currentStroke.last!.y) > 2 {
                        currentStroke.append(point)
                    }
                }
                .onEnded { _ in
                    drawing.addStroke(currentStroke, in: geometry.size)
                    currentStroke.removeAll()
                })
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Concept sketch")
        .accessibilityValue("\(drawing.polylines.count) strokes")
        .accessibilityHint("Draw here, or use Add rectangle below")
    }
}
