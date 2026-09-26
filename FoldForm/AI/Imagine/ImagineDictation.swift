import Foundation
import SwiftUI

/// Captions speech in Imagine without interpreting or executing CAD commands. The view decides when
/// to place a final sentence into its editable prompt; only its Generate button can send it onward.
@MainActor
final class ImagineDictation: ObservableObject {
    @Published private(set) var interim = ""
    @Published private(set) var lastFinal: FinalUtterance?
    @Published private(set) var isListening = false
    @Published private(set) var message: String?

    private let speech: SpeechService
    private var eventTask: Task<Void, Never>?

    init(speech: SpeechService) { self.speech = speech }
    deinit { eventTask?.cancel() }

    func start() async {
        guard !isListening else { return }
        if eventTask == nil {
            let events = speech.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
        }
        message = nil
        interim = ""
        isListening = true
        await speech.start()
    }

    func stop() async {
        guard isListening else { return }
        await speech.stop()
        for _ in 0..<200 where isListening {
            try? await Task.sleep(for: .milliseconds(10))
        }
        isListening = false
    }

    func cancel() async {
        isListening = false
        interim = ""
        await speech.cancel()
    }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .state(.idle): isListening = false; interim = ""
        case .state(.unavailable(let reason)): isListening = false; message = reason
        case .state: break
        case .interim(let text): if isListening { interim = text }
        case .final(let utterance):
            guard isListening else { return }
            interim = ""
            if !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastFinal = utterance }
        }
    }
}
