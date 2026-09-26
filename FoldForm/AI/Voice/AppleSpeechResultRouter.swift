import Foundation

/// Converts Apple's changing transcription into captions, and only its final result into a
/// command. A recognition segment has one identity even if the framework repeats a callback.
struct AppleSpeechResultRouter {
    private var completedSegments: Set<Int> = []
    private var finishingSegments: Set<Int> = []

    mutating func beginFinishing(segment: Int) -> Bool {
        finishingSegments.insert(segment).inserted
    }

    mutating func accept(_ text: String, isFinal: Bool, segment: Int) -> SpeechEvent? {
        guard !completedSegments.contains(segment) else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if isFinal {
            completedSegments.insert(segment)
            return .final(FinalUtterance(text: cleaned))
        }
        return .interim(cleaned)
    }
}
