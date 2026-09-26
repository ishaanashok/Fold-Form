import SwiftUI

/// An explicit sketch-and-prompt workspace. Generate is the only path into
/// `ImagineSession.generate`.
struct ImagineView: View {
    @ObservedObject var session: ImagineSession
    var unit: DimensionUnit
    var subscriptions: SubscriptionContext
    @ObservedObject private var entitlements: EntitlementStore
    @StateObject private var dictation: ImagineDictation
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = SketchDrawing()
    @State private var draft: ImaginePromptDraft
    @State private var allowDelete = false
    @State private var showUpgrade = false

    init(session: ImagineSession, unit: DimensionUnit, speech: SpeechService,
         subscriptions: SubscriptionContext, initialPrompt: String = "") {
        self.session = session
        self.unit = unit
        self.subscriptions = subscriptions
        self.entitlements = subscriptions.entitlements
        _dictation = StateObject(wrappedValue: ImagineDictation(speech: speech))
        _draft = State(initialValue: ImaginePromptDraft(text: initialPrompt))
    }

    private var isWorking: Bool {
        switch session.phase {
        case .readingSketch, .planning, .building: true
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sketchSection
                    descriptionSection
                    statusSection
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Imagine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        session.cancel()
                        Task { await dictation.cancel() }
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Label("Describe your idea, then tap Generate.", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        guard let png = drawing.pngData() else { return }
                        let submittedLines = drawing.polylines
                        let submittedDeletionChoice = allowDelete
                        Task {
                            await dictation.stop()
                            if let final = dictation.lastFinal { draft.append(final) }
                            await session.generate(prompt: draft.text, sketchPNG: png, polylines: submittedLines, units: unit.rawValue, allowDelete: submittedDeletionChoice)
                        }
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled((draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !dictation.isListening) || isWorking)
                    .accessibilityIdentifier("imagineGenerateButton")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $showUpgrade) {
            NavigationStack {
                UpgradeView(service: subscriptions.service, entitlements: entitlements)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { showUpgrade = false }
                                .labelStyle(.iconOnly)
                        }
                    }
            }
        }
        .onDisappear {
            session.cancel()
            Task { await dictation.cancel() }
        }
        .onChange(of: dictation.lastFinal) { _, utterance in
            if let utterance { draft.append(utterance) }
        }
    }

    private var sketchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sketch your idea").font(.headline)
            Text("Draw a rough shape or add a rectangle as a guide.")
                .font(.subheadline).foregroundStyle(.secondary)
            SketchCanvas(drawing: $drawing)
                .frame(height: 260)
            HStack {
                Button("Add rectangle", systemImage: "rectangle") { drawing.addGuideRectangle() }
                Spacer()
                Button("Clear sketch", systemImage: "trash", role: .destructive) { drawing.clear() }
                    .disabled(drawing.polylines.isEmpty)
            }
            .font(.subheadline)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe the design").font(.headline)
            TextField("For example, create a table", text: $draft.text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("imaginePromptField")
            HStack {
                Button(dictation.isListening ? "Stop dictation" : "Describe by voice", systemImage: dictation.isListening ? "stop.fill" : "mic.fill") {
                    Task {
                        if dictation.isListening { await dictation.stop() }
                        else { await dictation.start() }
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            if !dictation.interim.isEmpty {
                Text(dictation.interim).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityLabel("Hearing \(dictation.interim)")
            }
            if let message = dictation.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Allow removing parts in this plan", isOn: $allowDelete)
                .font(.subheadline)
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch session.phase {
        case .idle: EmptyView()
        case .readingSketch:
            ProgressView("Reading sketch…")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .planning:
            HStack { ProgressView(); Text("Planning features…") }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .building(_, let total):
            HStack { ProgressView(); Text("Applying \(total) \(total == 1 ? "step" : "steps")…") }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .done(let summary, let assumptions):
            VStack(alignment: .leading, spacing: 8) {
                Label(summary, systemImage: "checkmark")
                    .font(.headline).foregroundStyle(.green)
                if !assumptions.isEmpty {
                    Text("Assumptions").font(.subheadline.weight(.semibold))
                    ForEach(Array(assumptions.enumerated()), id: \.offset) { _, assumption in
                        Text("\(assumption.name): \(assumption.value) \(assumption.unit)")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .limitReached:
            VStack(alignment: .leading, spacing: 8) {
                Text("Today's Imagine limit is reached.")
                    .font(.subheadline)
                if !entitlements.isPro {
                    Button("Upgrade to Pro", systemImage: "sparkles") { showUpgrade = true }
                } else {
                    Text("Your 50 daily requests reset tomorrow.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
