import Foundation

/// Keeps typed text and finalized dictation together without appending the same speech event twice.
struct ImaginePromptDraft: Equatable {
    var text = ""
    private var appendedIDs: Set<UUID> = []

    mutating func append(_ utterance: FinalUtterance) {
        let sentence = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, appendedIDs.insert(utterance.id).inserted else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = typed.isEmpty ? sentence : typed + " " + sentence
    }
}
