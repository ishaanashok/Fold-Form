import Foundation
import MoonshineVoice

/// Live on-device transcription with Moonshine's small streaming English model. The model downloads on
/// first use; audio goes from the microphone to the model in memory and is never written to disk or sent
/// anywhere.
final class MoonshineSpeechService: SpeechService, @unchecked Sendable {
    let events: AsyncStream<SpeechEvent>
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private let lock = NSLock()
    private var mic: MicTranscriber?
    private var generation = 0
    private var loading: Task<Void, Never>?
    private let store: ModelStore
    private let manifest: ModelManifest

    init(store: ModelStore = ModelStore(), manifest: ModelManifest = MoonshineModel.manifest) {
        self.store = store
        self.manifest = manifest
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async {
        let generation = beginGeneration()
        let task = Task<Void, Never> { [weak self] in
            if let self { await self.run(generation: generation) }
        }
        lock.withLock { loading = task }
        await task.value
    }

    /// Ends the current run and finishes the line in progress, so a half-spoken command is not lost.
    func stop() async {
        continuation.yield(.state(.finalizing))
        await teardown(flush: true)
        continuation.yield(.state(.idle))
    }

    func cancel() async {
        await teardown(flush: false)
        continuation.yield(.state(.idle))
    }

    // MARK: Run

    private func beginGeneration() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    private func run(generation: Int) async {
        continuation.yield(.state(.downloading(0)))
        do {
            try await store.install(manifest) { [continuation] progress in
                continuation.yield(.state(.downloading(progress)))
            }
        } catch {
            guard isCurrent(generation) else { return }
            continuation.yield(.state(.unavailable(Self.reason(for: error))))
            return
        }
        guard isCurrent(generation), !Task.isCancelled else { return }
        let mic = MicTranscriber()
            .language("en")
            .modelArch(.smallStreaming)
            .modelsFrom(store.directory(for: manifest))
            .updateInterval(0.3)
        mic.addListener { [weak self] event in
            guard let self, self.isCurrent(generation) else { return }
            if let changed = event as? LineTextChanged {
                self.continuation.yield(.interim(changed.line.text))
            } else if let completed = event as? LineCompleted {
                let text = completed.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { self.continuation.yield(.final(FinalUtterance(text: text))) }
            } else if let failure = event as? TranscriptError {
                self.continuation.yield(.state(.unavailable("Speech recognition failed: \(failure.error.localizedDescription)")))
            }
        }
        do {
            try await mic.load()
            guard isCurrent(generation), !Task.isCancelled else { mic.close(); return }
            try mic.start()
        } catch {
            mic.close()
            guard isCurrent(generation) else { return }
            continuation.yield(.state(.unavailable(Self.reason(for: error))))
            return
        }
        guard isCurrent(generation) else { mic.close(); return }
        lock.withLock { self.mic = mic }
        continuation.yield(.state(.listening))
    }

    private func teardown(flush: Bool) async {
        let (mic, task, stoppingGeneration) = lock.withLock { () -> (MicTranscriber?, Task<Void, Never>?, Int) in
            let stoppingGeneration = generation
            // A stop can synchronously deliver LineCompleted. Keep this generation valid until
            // that flush finishes; cancellation must reject callbacks immediately.
            if !flush || self.mic == nil { generation += 1 }
            defer { self.mic = nil; loading = nil }
            return (self.mic, loading, stoppingGeneration)
        }
        task?.cancel()
        guard let mic else { return }
        // Stopping the stream flushes the open line into a LineCompleted; closing without stopping drops it.
        if flush {
            try? mic.stop()
            lock.withLock { if generation == stoppingGeneration { generation += 1 } }
        }
        mic.close()
    }

    private static func reason(for error: Error) -> String {
        if let storeError = error as? ModelStoreError {
            switch storeError {
            case .hashMismatch: return "The speech model couldn't be verified. Try again."
            default: return "The speech model couldn't be downloaded. Try again."
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("permission") { return "Microphone access is off. Turn it on in Settings." }
        if text.localizedCaseInsensitiveContains("offline") || text.localizedCaseInsensitiveContains("internet") || (error as NSError).domain == NSURLErrorDomain {
            return "The speech model needs a one-time download. Connect to the internet and try again."
        }
        return "Speech recognition couldn't start: \(text)"
    }
}
