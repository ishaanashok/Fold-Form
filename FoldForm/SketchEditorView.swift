import SwiftUI

/// A minimal sketch canvas: draw a rectangle or circle by dragging, on a fixed grid. Real, editable
/// sketch geometry (not a placeholder) that feeds `Sketch.resolveClosedProfile()` and therefore
/// Extrude/Hole — but intentionally limited to a single closed shape per sketch, matching the
/// GeometryKernel's current scope (see GeometryKernel.swift's top-level doc comment).
struct SketchEditorView: View {
    @EnvironmentObject var appModel: AppModel
    let sketchID: UUID

    enum Tool { case rectangle, circle }
    @State private var tool: Tool = .rectangle
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private let pixelsPerMeter: CGFloat = 800

    var body: some View {
        VStack(spacing: 8) {
            Picker("Tool", selection: $tool) {
                Text("Rectangle").tag(Tool.rectangle)
                Text("Circle").tag(Tool.circle)
            }
            .pickerStyle(.segmented)

            Canvas { context, size in
                drawGrid(context: context, size: size)
                if let sketch = currentSketch {
                    for entity in sketch.entities {
                        draw(entity, context: context, size: size)
                    }
                }
                if let start = dragStart, let current = dragCurrent {
                    let rect = CGRect(origin: start, size: CGSize(width: current.x - start.x, height: current.y - start.y))
                    context.stroke(Path(rect), with: .color(.cyan), lineWidth: 1)
                }
            }
            .background(Color.black.opacity(0.85))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        commitShape(from: value.startLocation, to: value.location, canvasSize: lastCanvasSize)
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
            .overlay(GeometryReader { proxy in
                Color.clear.onAppear { lastCanvasSize = proxy.size }
            })

            if let error = validationMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            Button("Done") { appModel.isSketchEditing = false }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @State private var lastCanvasSize: CGSize = .init(width: 300, height: 300)

    private var currentSketch: Sketch? {
        appModel.document.partStudio.featureTree.sketches.first { $0.id == sketchID }
    }

    private var validationMessage: String? {
        guard let sketch = currentSketch else { return nil }
        do { _ = try sketch.resolveClosedProfile(); return nil }
        catch { return error.localizedDescription }
    }

    private func toMeters(_ point: CGPoint, canvasSize: CGSize) -> SIMD2<Double> {
        let cx = canvasSize.width / 2, cy = canvasSize.height / 2
        return SIMD2<Double>(Double(point.x - cx) / Double(pixelsPerMeter), Double(cy - point.y) / Double(pixelsPerMeter))
    }

    private func commitShape(from start: CGPoint, to end: CGPoint, canvasSize: CGSize) {
        guard var sketch = currentSketch else { return }
        let p1 = toMeters(start, canvasSize: canvasSize)
        let p2 = toMeters(end, canvasSize: canvasSize)
        let width = abs(p2.x - p1.x)
        let height = abs(p2.y - p1.y)
        guard width > 0.002, height > 0.002 else { return }
        let origin = SIMD2<Double>((p1.x + p2.x) / 2, (p1.y + p2.y) / 2)

        sketch.entities.removeAll() // single-profile-per-sketch scope, see type doc comment above
        switch tool {
        case .rectangle:
            sketch.entities.append(.rectangle(id: UUID(), origin: origin, width: width, height: height, construction: false))
        case .circle:
            sketch.entities.append(.circle(id: UUID(), center: origin, radius: max(width, height) / 2, construction: false))
        }
        appModel.document.partStudio.featureTree.updateSketch(sketch)
        appModel.document.partStudio.regenerate()
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let step: CGFloat = 20
        var x: CGFloat = 0
        while x < size.width {
            context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) }, with: .color(.white.opacity(0.08)))
            x += step
        }
        var y: CGFloat = 0
        while y < size.height {
            context.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: size.width, y: y)) }, with: .color(.white.opacity(0.08)))
            y += step
        }
    }

    private func draw(_ entity: SketchEntity, context: GraphicsContext, size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2
        func toPixels(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: cx + CGFloat(p.x) * pixelsPerMeter, y: cy - CGFloat(p.y) * pixelsPerMeter)
        }
        let color: Color = entity.isConstruction ? .blue.opacity(0.6) : .green
        switch entity {
        case .rectangle(_, let origin, let w, let h, _):
            let topLeft = toPixels(SIMD2(origin.x - w / 2, origin.y + h / 2))
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: CGFloat(w) * pixelsPerMeter, height: CGFloat(h) * pixelsPerMeter)
            context.stroke(Path(rect), with: .color(color), lineWidth: 2)
        case .circle(_, let center, let r, _):
            let c = toPixels(center)
            let rect = CGRect(x: c.x - CGFloat(r) * pixelsPerMeter, y: c.y - CGFloat(r) * pixelsPerMeter, width: CGFloat(r) * 2 * pixelsPerMeter, height: CGFloat(r) * 2 * pixelsPerMeter)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        case .line(_, let p1, let p2, _):
            context.stroke(Path { $0.move(to: toPixels(p1)); $0.addLine(to: toPixels(p2)) }, with: .color(color), lineWidth: 2)
        case .polygon(_, let points, _):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: toPixels(first))
            for p in points.dropFirst() { path.addLine(to: toPixels(p)) }
            path.closeSubpath()
            context.stroke(path, with: .color(color), lineWidth: 2)
        case .arc(_, let center, let r, let start, let end, _):
            let c = toPixels(center)
            var path = Path()
            path.addArc(center: c, radius: CGFloat(r) * pixelsPerMeter, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }
}
