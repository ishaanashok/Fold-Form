import Foundation

/// One finished sentence from the speech recogniser. Interim (still-changing) text has no type that
/// can reach an interpreter, so it can never run a command.
struct FinalUtterance: Equatable, Sendable {
    /// Identifies this sentence, so one delivered twice runs once.
    let id: UUID
    let text: String
    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum InterpretResult: Equatable, Sendable {
    /// Tool calls to validate and run, in order.
    case calls([ToolCall])
    /// Say this to the user and do nothing.
    case clarify(String)
    /// A creative request the local interpreter should not guess at; the Imagine mode handles it.
    case needsImagine
}

protocol CommandInterpreter: Sendable {
    func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult
}
