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
    @State private var moveMode = false
    /// The 3D scene, owned here so the HUD's hold/undo buttons can act on it.
    @StateObject private var viewport = ViewportEntities()

    var body: some View {
        // The HUD items are content-sized overlays, not a full-frame VStack/GeometryReader layered
        // over the viewport: SwiftUI treats a full-frame container as hit-testable even where it is
        // visually empty, and it swallowed every drag and pinch meant for the 3D view beneath.
        RealityViewport(entities: viewport, oneFingerPans: moveMode)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 10) {
                    waffleButton
                    sketchButton
                    moveButton
                    holdButton
                    if viewport.foldCount > 0 { undoButton; resetButton }
                    resetAllButton
                }
                .padding(16)
            }
            .overlay {
                if viewport.sketch.isActive {
                    SketchOverlay(sketch: viewport.sketch, camera: viewport.camera)
                }
            }
            .overlay(alignment: .bottom) {
                if viewport.sketch.isActive {
                    SketchToolbar(
                        sketch: viewport.sketch,
                        onExtrudeConfirm: { viewport.confirmExtrude() },
                        onDone: { viewport.endSketch() }
                    )
                    .padding(.bottom, 14)
                }
            }
            .overlay { menuLayer }
            .overlay(alignment: .topTrailing) {
                ViewCubeView(axes: viewport.viewAxes) { viewport.snap(to: $0) }
                    .padding(16)
            }
            .overlay(alignment: .bottomTrailing) { hudPill.padding(16) }
        .environmentObject(appModel)
        .bindHingeInput(appModel.hingeInput)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTools) {
            ControlPanelView(onStartDemo: {
                viewport.resetEverything()
                appModel.startDemo()
            }, onTool: { tool in
                switch tool {
                case .sketch:
                    showTools = false
                    viewport.beginSketch()
                case .extrude where viewport.sketch.isActive:
                    showTools = false
                    viewport.sketch.startExtrude()
                default:
                    appModel.activate(tool)
                }
            })
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
        .accessibilityIdentifier("toolsButton")
        .accessibilityLabel("Tools")
    }

    /// Sketch: draw lines, rectangles and circles right on the model's surface, then extrude them.
    private var sketchButton: some View {
        let active = viewport.sketch.isActive
        return Button {
            if active { viewport.endSketch() } else { viewport.beginSketch() }
        } label: {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.white)
                .padding(10)
                .background(active ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityIdentifier("sketchButton")
        .accessibilityLabel("Sketch")
        .accessibilityValue(active ? "on" : "off")
    }

    /// Complete reset: back to the very first flat plate, with every extra part, fold and sketch gone.
    private var resetAllButton: some View {
        Button {
            viewport.resetEverything()
        } label: {
            Image(systemName: "gobackward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("resetAllButton")
        .accessibilityLabel("Reset everything")
    }

    /// The press-and-hold pop-up, with a see-through layer behind it so tapping elsewhere closes it.
    @ViewBuilder private var menuLayer: some View {
        if let menu = viewport.menu {
            GeometryReader { proxy in
                ZStack {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { viewport.dismissMenu() }
                    PartMenuView(
                        menu: menu,
                        canPaste: viewport.hasClipboard,
                        canDelete: menu.partID != FoldSession.primaryID,
                        onDuplicate: { if let id = menu.partID { viewport.duplicate(id) } },
                        onCopy: { if let id = menu.partID { viewport.copy(id) } },
                        onDelete: { if let id = menu.partID { viewport.delete(id) } },
                        onPaste: { viewport.paste(at: menu.point) }
                    )
                    .position(
                        x: min(max(menu.point.x, 130), max(proxy.size.width - 130, 130)),
                        y: max(menu.point.y - 60, 50)
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Move mode: a plain one-finger / mouse drag moves the object instead of rotating it. Two
    /// fingers always move it too; this is for inputs (like a mouse in an emulator) where two-finger
    /// gestures are awkward or unavailable.
    private var moveButton: some View {
        Button {
            moveMode.toggle()
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(moveMode ? Color.black : Color.white)
                .padding(10)
                .background(moveMode ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityIdentifier("moveToggle")
        .accessibilityLabel("Move")
        .accessibilityValue(moveMode ? "on" : "off")
    }

    /// Hold: bakes the fold currently shown and keeps it while the phone is opened back up. It only
    /// lets go once the hinge is flat again, and the next fold then builds on the held shape.
    private var holdButton: some View {
        let canHold = !viewport.isHolding && appModel.hingeInput.bendAngleRadians > FoldSession.flatThresholdRadians
        return Button {
            viewport.holdFold()
        } label: {
            Image(systemName: viewport.isHolding ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(viewport.isHolding ? Color.black : Color.white)
                .padding(10)
                .background(viewport.isHolding ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .opacity(canHold || viewport.isHolding ? 1 : 0.4)
        }
        .disabled(!canHold)
        .accessibilityIdentifier("holdButton")
        .accessibilityLabel("Hold fold")
        .accessibilityValue(viewport.isHolding ? "held" : "off")
    }

    private var undoButton: some View {
        Button {
            viewport.undoFold()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("undoFoldButton")
        .accessibilityLabel("Undo last held fold")
    }

    private var resetButton: some View {
        Button {
            viewport.resetFolds()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("resetFoldsButton")
        .accessibilityLabel("Reset all folds")
    }

    /// The one persistent piece of HUD: current bend angle plus a one-word status, small enough to
    /// stay out of the way of the model itself (plan's "large angle readout" now lives here, tucked
    /// into a corner instead of a whole docked panel).
    private var hudPill: some View {
        HStack(spacing: 6) {
            Text("\(Int(appModel.hingeInput.bendAngleDegrees.rounded()))°")
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
        if viewport.isHolding { return "HELD" }
        if appModel.hingeInput.isDebugOverridden { return "DEBUG" }
        if appModel.collision.maxBendReached { return "LIMIT" }
        if appModel.hingeInput.bendAngleDegrees > 1 { return "BENDING" }
        return "READY"
    }

    private var hudStatusColor: Color {
        if viewport.isHolding { return .cyan }
        if appModel.hingeInput.isDebugOverridden { return .orange }
        if appModel.collision.maxBendReached { return .orange }
        if appModel.hingeInput.bendAngleDegrees > 1 { return .yellow }
        return .green
    }
}
