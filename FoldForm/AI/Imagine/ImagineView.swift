import SwiftUI

/// An explicit sketch-and-prompt workspace. Opening it does not call the cloud service; Generate
/// is the only path into `ImagineSession.generate`.
struct ImagineView: View {
    @ObservedObject var session: ImagineSession
    @StateObject private var dictation: ImagineDictation
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = SketchDrawing()
    @State private var prompt = ""
    @State private var allowDelete = false
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyMessage: String?

    init(session: ImagineSession, speech: SpeechService) {
        self.session = session
        _dictation = StateObject(wrappedValue: ImagineDictation(speech: speech))
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
                    keySection
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
                    Label("Your sketch, prompt, and current design are sent to NVIDIA when you tap Generate.", systemImage: "cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        guard let png = drawing.pngData() else { return }
                        let submittedPrompt = prompt
                        let submittedLines = drawing.polylines
                        let submittedDeletionChoice = allowDelete
                        Task {
                            await dictation.stop()
                            await session.generate(prompt: submittedPrompt, sketchPNG: png, polylines: submittedLines, allowDelete: submittedDeletionChoice)
                        }
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    .accessibilityIdentifier("imagineGenerateButton")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
        .onAppear { readKeyStatus() }
        .onDisappear {
            session.cancel()
            Task { await dictation.cancel() }
        }
        .onChange(of: dictation.lastFinal) { _, utterance in
            guard let utterance else { return }
            let sentence = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sentence : prompt + " " + sentence
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
            TextField("For example, add a sloped phone support", text: $prompt, axis: .vertical)
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

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NVIDIA API key", systemImage: "key").font(.headline)
            if hasKey {
                HStack {
                    Label("Key saved in Keychain", systemImage: "checkmark.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { removeKey() }
                }
            } else {
                SecureField("Enter your NVIDIA API key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Save key") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let keyMessage { Text(keyMessage).font(.footnote).foregroundStyle(.red) }
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
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func readKeyStatus() {
        do { hasKey = try KeychainStore().apiKey() != nil }
        catch { keyMessage = "The Keychain isn't available right now." }
    }

    private func saveKey() {
        do {
            try KeychainStore().save(keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            keyInput = ""
            hasKey = true
            keyMessage = nil
        } catch { keyMessage = "Couldn't save the key. Try again." }
    }

    private func removeKey() {
        do {
            try KeychainStore().delete()
            hasKey = false
            keyMessage = nil
        } catch { keyMessage = "Couldn't remove the key. Try again." }
    }
}
