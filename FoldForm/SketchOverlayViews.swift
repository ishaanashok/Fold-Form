import SwiftUI
import simd

/// Draws the sketch plane, the shapes on it, and the shape being dragged, on top of the 3D view.
/// It only draws; touches pass straight through to the viewport underneath.
struct SketchOverlay: View {
    @ObservedObject var sketch: SketchController
    let camera: CameraRig

    var body: some View {
        Canvas { context, size in
            guard let plane = sketch.plane else { return }

            func project(_ p: SIMD2<Float>) -> CGPoint? { camera.project(plane.world(p), in: size) }
            func path(_ points: [SIMD2<Float>], closed: Bool) -> Path? {
                let projected = points.compactMap(project)
                guard projected.count == points.count, let first = projected.first else { return nil }
                var path = Path()
                path.move(to: first)
                projected.dropFirst().forEach { path.addLine(to: $0) }
                if closed { path.closeSubpath() }
                return path
            }

            // The drawing surface: a faint grid so it's clear where shapes will land.
            let half: Float = 0.16, step: Float = 0.02
            var grid = Path()
            var value = -half
            while value <= half + 1e-4 {
                if let a = project(SIMD2(value, -half)), let b = project(SIMD2(value, half)) { grid.move(to: a); grid.addLine(to: b) }
                if let a = project(SIMD2(-half, value)), let b = project(SIMD2(half, value)) { grid.move(to: a); grid.addLine(to: b) }
                value += step
            }
            context.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 1)
            if let border = path([SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half)], closed: true) {
                context.fill(border, with: .color(.white.opacity(0.03)))
                context.stroke(border, with: .color(.white.opacity(0.25)), lineWidth: 1)
            }

            // Closed shapes get a fill so it's clear they can be extruded.
            for profile in sketch.profiles {
                if let shape = path(profile, closed: true) { context.fill(shape, with: .color(.cyan.opacity(0.22))) }
            }

            func stroke(_ shape: SketchShape, color: Color, dashed: Bool) {
                let outline: [SIMD2<Float>]
                let closed: Bool
                if case .line(let a, let b) = shape { outline = [a, b]; closed = false }
                else if let o = SketchGeometry.outline(of: shape) { outline = o; closed = true }
                else { return }
                guard let p = path(outline, closed: closed) else { return }
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dashed ? [6, 5] : []))
                if case .line = shape {
                    for end in outline {
                        if let point = project(end) {
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(color))
                        }
                    }
                }
            }
            for shape in sketch.shapes { stroke(shape, color: .cyan, dashed: false) }
            if let draft = sketch.draft { stroke(draft, color: .yellow, dashed: true) }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Tool choice, undo, and the extrude / done buttons, along the bottom while sketching.
struct SketchToolbar: View {
    @ObservedObject var sketch: SketchController
    let onExtrudeConfirm: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(sketch.prompt)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("sketchPrompt")

            HStack(spacing: 6) {
                if sketch.isExtruding {
                    chip("Cancel", systemImage: "xmark", id: "extrudeCancel") { sketch.cancelExtrude() }
                    chip("Confirm", systemImage: "checkmark", tint: .green, id: "extrudeConfirm") { onExtrudeConfirm() }
                } else {
                    ForEach(SketchTool.allCases) { tool in
                        chip(tool.rawValue, systemImage: tool.systemImage, selected: sketch.tool == tool, id: "tool\(tool.rawValue)") {
                            sketch.tool = tool
                        }
                    }
                    Divider().frame(height: 22)
                    chip("Undo", systemImage: "arrow.uturn.backward", enabled: !sketch.shapes.isEmpty, id: "sketchUndo") { sketch.undoShape() }
                    chip("Extrude", systemImage: "arrow.up.to.line", tint: .cyan, enabled: sketch.canExtrude, id: "extrudeButton") { sketch.startExtrude() }
                    chip("Done", systemImage: "checkmark.circle", id: "sketchDone") { onDone() }
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func chip(_ title: String, systemImage: String, selected: Bool = false, tint: Color = .white, enabled: Bool = true, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.black : tint)
            .frame(minWidth: 48)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .background(selected ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.35)
        }
        .disabled(!enabled)
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
    }
}

/// The pop-up from pressing and holding: copy or duplicate a part, or paste onto empty space.
struct PartMenuView: View {
    let menu: PartMenu
    let canPaste: Bool
    let canDelete: Bool
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPaste: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if menu.partID != nil {
                item("Duplicate", "plus.square.on.square", id: "menuDuplicate", action: onDuplicate)
                item("Copy", "doc.on.doc", id: "menuCopy", action: onCopy)
                if canDelete { item("Delete", "trash", tint: .red, id: "menuDelete", action: onDelete) }
            } else if canPaste {
                item("Paste", "doc.on.clipboard", id: "menuPaste", action: onPaste)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.4), radius: 8)
    }

    private func item(_ title: String, _ image: String, tint: Color = .white, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: image).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(minWidth: 62)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier(id)
    }
}
