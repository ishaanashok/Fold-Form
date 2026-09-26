import SwiftUI
import UIKit

@main
struct FoldFormApp: App {
    @StateObject private var library = DesignLibrary()

    var body: some Scene {
        WindowGroup {
            AppRoot(library: library)
        }
    }
}

/// A design that is open in the editor.
private struct OpenDesign: Identifiable {
    let id: UUID
    let name: String
    let loaded: LoadedDesign
}

/// Dashboard or editor. Opening a design builds a fresh editor for it (`.id`), so nothing carries
/// over between designs.
struct AppRoot: View {
    @ObservedObject var library: DesignLibrary
    @State private var open: OpenDesign?
    @AppStorage("darkMode") private var darkMode = true

    var body: some View {
        ZStack {
            if let open {
                EditorView(library: library, designID: open.id, designName: open.name, loaded: open.loaded, onClose: { self.open = nil })
                    .id(open.id)
                    .transition(.opacity)
            } else {
                DashboardView(library: library, onOpen: openDesign)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: open?.id)
        .preferredColorScheme(darkMode ? .dark : .light)
        .alert("Couldn't open design", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.lastError ?? "") }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-FoldFormOpenNewDesign"), open == nil,
               let design = library.createDesign(template: .sheetPlate) {
                openDesign(design.id)
            }
            #endif
        }
    }

    private func openDesign(_ id: UUID) {
        guard let manifest = library.designs.first(where: { $0.id == id }),
              let loaded = try? library.open(id) else { return }
        open = OpenDesign(id: id, name: manifest.name, loaded: loaded)
    }
}

/// Full-bleed 3D viewport spanning the entire window (both panels across the physical crease),
/// the way a modeling tool's canvas fills the screen. Modeling tools, the feature tree, and sheet
/// metal/inspection panels are not permanently docked; they live behind a single waffle-menu
/// button and open as a sheet, so the model itself has the whole screen instead of sharing it with
/// a docked control column.
struct EditorView: View {
    @ObservedObject var library: DesignLibrary
    let designID: UUID
    let designName: String
    let onClose: () -> Void
    @StateObject private var appModel: AppModel
    @StateObject private var viewport: ViewportEntities
    @StateObject private var session: DesignSession
    @StateObject private var voice: VoiceCommandSession
    @StateObject private var imagine: ImagineSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showTools = false
    @State private var showImagine = false
    @AppStorage("darkMode") private var darkMode = true
    @AppStorage("showDimensions") private var showDimensions = false
    @AppStorage("dimensionUnit") private var dimensionUnit = DimensionUnit.centimetres
    @State private var moveMode = false
    @State private var exportFile: ExportFile?

    init(library: DesignLibrary, designID: UUID, designName: String, loaded: LoadedDesign, onClose: @escaping () -> Void) {
        self.library = library
        self.designID = designID
        self.designName = designName
        self.onClose = onClose
        let model = AppModel(loaded: loaded)
        let viewport = ViewportEntities(startingView: loaded.camera.map { (camera: $0, corner: loaded.corner) })
        _appModel = StateObject(wrappedValue: model)
        _viewport = StateObject(wrappedValue: viewport)
        let executor = CADActionExecutor(appModel: model, viewport: viewport)
        _voice = StateObject(wrappedValue: VoiceCommandSession(
            speech: SpeechServiceFactory.make(),
            interpreter: CompositeInterpreter(needle: NeedleInterpreter(runtime: CactusNeedleRuntime.shared), fallback: RuleBasedInterpreter()),
            executor: executor,
            contextProvider: { executor.currentContext() }
        ))
        _imagine = StateObject(wrappedValue: ImagineSession(
            appModel: model, viewport: viewport, executor: executor, generator: NIMClient()
        ))
        _session = StateObject(wrappedValue: DesignSession(designID: designID, library: library))
    }

    var body: some View {
        // The HUD items are content-sized overlays, not a full-frame VStack/GeometryReader layered
        // over the viewport: SwiftUI treats a full-frame container as hit-testable even where it is
        // visually empty, and it swallowed every drag and pinch meant for the 3D view beneath.
        RealityViewport(entities: viewport, oneFingerPans: moveMode, darkMode: darkMode)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 10) {
                    waffleButton
                    sketchButton
                    micButton
                    imagineButton
                    moveButton
                    undoEditButton
                    touchUpButton
                    holdButton
                    if viewport.foldCount > 0 { undoButton; resetButton }
                    resetAllButton
                }
                .padding(16)
            }
            .overlay {
                if showDimensions {
                    DimensionOverlay(viewport: viewport, sketch: viewport.sketch, unit: dimensionUnit)
                }
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
            .overlay(alignment: .trailing) {
                if viewport.sketch.isExtruding {
                    ExtrudeSlider(sketch: viewport.sketch)
                        .padding(.trailing, 4)
                }
            }
            .overlay { menuLayer }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    ViewCubeWidget(axes: viewport.viewAxes, onSelect: { viewport.snap(to: $0) }, onStep: { viewport.step($0) })
                    shareMenu
                }
                .padding(16)
            }
            .overlay(alignment: .bottomTrailing) { hudPill.padding(16) }
            .overlay(alignment: .bottom) {
                VoiceCaptionView(phase: voice.phase)
                    .padding(.bottom, viewport.sketch.isActive ? 84 : 20)
                    .animation(.easeOut(duration: 0.2), value: voice.phase)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    designPill
                    presenceStrip
                    touchUpBanner
                }
            }
        .onAppear {
            viewport.referenceVisibility.darkMode = darkMode
            session.capture = { [weak viewport] in viewport?.captureDesign() }
            viewport.onContentChange = { [weak session] in session?.contentChanged() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.saveNow()
                // The microphone is never left open behind another app.
                Task { await voice.cancel() }
                imagine.cancel()
            }
        }
        .onChange(of: darkMode) { _, new in viewport.referenceVisibility.darkMode = new }
        .environmentObject(appModel)
        .bindHingeInput(appModel.hingeInput)
        .sheet(isPresented: $showTools) {
            ViewOptionsView(
                reference: Binding(get: { viewport.referenceVisibility }, set: { viewport.referenceVisibility = $0 }),
                darkMode: $darkMode,
                showDimensions: $showDimensions,
                unit: $dimensionUnit
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showImagine) {
            ImagineView(session: imagine, speech: SpeechServiceFactory.make())
        }
    }

    @ViewBuilder private var presenceStrip: some View {
        let people = library.collaboration.collaborators(for: designID)
        if !people.isEmpty {
            HStack(spacing: -6) {
                ForEach(people.prefix(4)) { person in
                    Text(String(person.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                Text("Preview").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10)
            }
            .allowsHitTesting(false)
        }
    }

    /// Back to the dashboard: saves first, then shows the design's name.
    private var designPill: some View {
        Button {
            session.close()
            library.checkpointIfChanged(designID)
            onClose()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                Text(library.designs.first { $0.id == designID }?.name ?? designName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.top, 16)
        .accessibilityIdentifier("designsButton")
        .accessibilityLabel("Back to designs")
    }

    private var waffleButton: some View {
        Button {
            showTools = true
        } label: {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("toolsButton")
        .accessibilityLabel("Tools")
    }

    /// Share: pick a 3D file format, then send or save the model (AirDrop, Files, other apps).
    private var shareMenu: some View {
        Menu {
            Section("Export model as") {
                ForEach(ExportFormat.allCases) { format in
                    Button("\(format.rawValue) · \(format.detail)") { share(format) }
                        .accessibilityIdentifier("export\(format.rawValue)")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("shareButton")
        .accessibilityLabel("Share model")
        .sheet(item: $exportFile) { file in
            ActivityView(url: file.url)
                .presentationDetents([.medium, .large])
        }
    }

    private func share(_ format: ExportFormat) {
        guard let mesh = viewport.exportMesh() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FoldForm-Model.\(format.fileExtension)")
        do {
            try ModelExporter.data(for: mesh, as: format).write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            appModel.reportExportFailure(error)
        }
    }

    /// Sketch: draw lines, rectangles and circles right on the model's surface, then extrude them.
    private var sketchButton: some View {
        let active = viewport.sketch.isActive
        return Button {
            if active { viewport.endSketch() } else { viewport.beginSketch() }
        } label: {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.primary)
                .padding(10)
                .background(active ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityIdentifier("sketchButton")
        .accessibilityLabel("Sketch")
        .accessibilityValue(active ? "on" : "off")
    }

    /// Hands-free: listen, show captions, and act on each finished sentence.
    private var micButton: some View {
        let active = voice.isActive
        return Button {
            Task {
                if active {
                    await voice.stop()
                } else {
                    // The interpreter model downloads once, on first use; the rules cover until it is ready.
                    Task { await CactusNeedleRuntime.shared.prepare() }
                    await voice.start()
                }
            }
        } label: {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.primary)
                .padding(10)
                .background(active ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityIdentifier("micButton")
        .accessibilityLabel("Voice control")
        .accessibilityValue(active ? "listening" : "off")
    }

    private var imagineButton: some View {
        Button {
            Task {
                await voice.cancel()
                showImagine = true
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("imagineButton")
        .accessibilityLabel("Imagine")
        .accessibilityHint("Sketch and describe a design to generate editable parts")
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
                .foregroundStyle(moveMode ? Color.black : Color.primary)
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
                .foregroundStyle(viewport.isHolding ? Color.black : Color.primary)
                .padding(10)
                .background(viewport.isHolding ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .opacity(canHold || viewport.isHolding ? 1 : 0.4)
        }
        .disabled(!canHold)
        .accessibilityIdentifier("holdButton")
        .accessibilityLabel("Hold fold")
        .accessibilityValue(viewport.isHolding ? "held" : "off")
    }

    private var undoEditButton: some View {
        Button {
            viewport.undo()
        } label: {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(viewport.hasUndo ? 1 : 0.4)
        }
        .disabled(!viewport.hasUndo)
        .accessibilityIdentifier("undoEditButton")
        .accessibilityLabel("Undo")
    }

    /// Touch up: smooth odd bumps and snap to the shape that was probably meant.
    private var touchUpButton: some View {
        let working = viewport.touchUpStatus == .working
        return Button {
            viewport.touchUp()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(working ? 0.4 : 1)
        }
        .disabled(working)
        .accessibilityIdentifier("touchUpButton")
        .accessibilityLabel("Touch up")
    }

    @ViewBuilder private var touchUpBanner: some View {
        switch viewport.touchUpStatus {
        case .idle:
            EmptyView()
        case .working:
            Text("Touching up…")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 16)
                .allowsHitTesting(false)
        case .message(let text):
            Text(text)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 16)
                .allowsHitTesting(false)
                .accessibilityIdentifier("touchUpMessage")
        }
    }

    private var undoButton: some View {
        Button {
            viewport.undoFold()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
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
                .foregroundStyle(.primary)
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
            if viewport.cornerStyle == .sharp {
                Text("SHARP")
                    .font(.caption2.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.yellow, in: Capsule())
                    .accessibilityIdentifier("cornerTag")
            }
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

/// A model file ready to hand to the share sheet.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet (AirDrop, Save to Files, Messages, other apps) for one file.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
