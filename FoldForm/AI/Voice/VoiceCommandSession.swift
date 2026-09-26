import Foundation
import SwiftUI

enum VoicePhase: Equatable {
    case idle
    /// Listening; the text is what has been heard so far in the current sentence.
    case listening(String)
    case interpreting(String)
    case executing([String])
    case done(String)
    /// The sentence, and why nothing (or not everything) happened.
    case failed(String, String)
}

/// Hands-free voice control: live captions while someone speaks, and one finished sentence at a time
/// turned into design changes. Only a final sentence can change the design; interim text is shown
/// and nothing more.
@MainActor
final class VoiceCommandSession: ObservableObject {
    @Published private(set) var phase: VoicePhase = .idle
    /// True from the moment listening starts until it is stopped.
    @Published private(set) var isActive = false
    /// How long a result stays on screen before the caption goes back to listening.
    var resultDisplayDuration: Double = 3.5

    private let speech: SpeechService
    private let interpreter: CommandInterpreter
    private let executor: CADActionExecutor
    private let contextProvider: () -> ToolContext

    private var eventTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var seen: Set<UUID> = []
    /// The newest sentence being worked on; an older one that finishes later is dropped.
    private var latest: UUID?
    private var stopping = false

    init(speech: SpeechService, interpreter: CommandInterpreter, executor: CADActionExecutor, contextProvider: @escaping () -> ToolContext) {
        self.speech = speech
        self.interpreter = interpreter
        self.executor = executor
        self.contextProvider = contextProvider
    }

    deinit { eventTask?.cancel() }

    // MARK: Control

    func start() async {
        guard !isActive else { return }
        isActive = true
        stopping = false
        phase = .listening("")
        if eventTask == nil {
            let events = speech.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
        }
        await speech.start()
    }

    /// Stops listening, still acting on a sentence that was already heard.
    func stop() async {
        guard isActive else { return }
        stopping = true
        await speech.stop()
        // The service reports idle once it has delivered everything; that ends the session. Wait for
        // it, but never hang on a service that doesn't say so.
        for _ in 0..<200 where isActive { try? await Task.sleep(nanoseconds: 10_000_000) }
        if isActive {
            isActive = false
            stopping = false
            if !isBusy { phase = .idle }
        }
    }

    /// Stops at once. Anything heard but not yet acted on is dropped.
    func cancel() async {
        isActive = false
        stopping = false
        latest = nil
        resetTask?.cancel()
        phase = .idle
        await speech.cancel()
    }

    // MARK: Events

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .state(let state):
            switch state {
            case .idle:
                if !isActive || stopping {
                    isActive = false
                    stopping = false
                    if !isBusy { phase = .idle }
                }
            case .listening, .finalizing:
                break
            case .unavailable(let reason):
                isActive = false
                stopping = false
                phase = .failed("", reason)
            }
        case .interim(let text):
            guard isActive, !isBusy else { return }
            resetTask?.cancel()
            phase = .listening(text)
        case .final(let utterance):
            guard isActive || stopping else { return }
            Task { await process(utterance) }
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .interpreting, .executing: true
        default: false
        }
    }

    // MARK: One sentence

    private func process(_ utterance: FinalUtterance) async {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, seen.insert(utterance.id).inserted else { return }
        latest = utterance.id
        resetTask?.cancel()
        phase = .interpreting(text)

        let result = await interpreter.interpret(utterance, context: contextProvider())
        // Cancelled, stopped for good, or a newer sentence has taken over.
        guard latest == utterance.id, isActive || stopping else { return }

        switch result {
        case .clarify(let message):
            show(.failed(text, message))
        case .needsImagine:
            show(.failed(text, "This request needs Imagine"))
        case .calls(let calls):
            let actions: [CADAction]
            do {
                actions = try ToolCatalog.validateSequence(calls, context: contextProvider())
            } catch let error as ToolError {
                return show(.failed(text, error.message))
            } catch {
                return show(.failed(text, "I couldn't run that"))
            }
            phase = .executing(actions.map(\.summary))
            let outcome = executor.run(actions)
            if let failure = outcome.failure {
                let kept = outcome.completed > 0 ? "Did \(outcome.completed) of \(actions.count). " : ""
                show(.failed(text, kept + failure))
            } else {
                show(.done(actions.map(\.summary).joined(separator: " · ")))
            }
        }
    }

    /// Shows a result, then goes back to listening if the session is still on.
    private func show(_ result: VoicePhase) {
        phase = result
        resetTask?.cancel()
        let duration = resultDisplayDuration
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == result else { return }
            self.phase = self.isActive ? .listening("") : .idle
        }
    }
}
