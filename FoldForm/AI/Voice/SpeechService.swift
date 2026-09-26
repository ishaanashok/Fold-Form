import Foundation

enum SpeechState: Equatable, Sendable {
    case idle
    case listening
    case finalizing
    /// Speech can't run (no microphone permission, model missing); the text says why.
    case unavailable(String)
}

enum SpeechEvent: Equatable, Sendable {
    case state(SpeechState)
    /// Text that is still changing. Shown, never acted on.
    case interim(String)
    /// A finished sentence. The only event a command can come from.
    case final(FinalUtterance)
}

/// A source of live transcription. Audio never leaves the device or reaches disk.
protocol SpeechService: AnyObject, Sendable {
    var events: AsyncStream<SpeechEvent> { get }
    func start() async
    /// Stops listening after delivering what was already heard.
    func stop() async
    /// Stops at once and discards anything not yet delivered.
    func cancel() async
}

/// A service whose events the caller writes. For tests and previews.
final class ScriptedSpeechService: SpeechService, @unchecked Sendable {
    let events: AsyncStream<SpeechEvent>
    private let continuation: AsyncStream<SpeechEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .unbounded)
    }

    func emit(_ event: SpeechEvent) { continuation.yield(event) }
    func start() async { continuation.yield(.state(.listening)) }
    func stop() async { continuation.yield(.state(.idle)) }
    func cancel() async { continuation.yield(.state(.idle)) }
}

/// Stands in when the speech model isn't there, so the button can say why instead of doing nothing.
final class UnavailableSpeechService: SpeechService, @unchecked Sendable {
    let events: AsyncStream<SpeechEvent>
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private let reason: String

    init(reason: String) {
        self.reason = reason
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async { continuation.yield(.state(.unavailable(reason))) }
    func stop() async { continuation.yield(.state(.idle)) }
    func cancel() async { continuation.yield(.state(.idle)) }
}

enum SpeechServiceFactory {
    /// The speech service for this device. Nothing loads or listens until `start()`.
    @MainActor static func make() -> SpeechService { MoonshineSpeechService() }
}
