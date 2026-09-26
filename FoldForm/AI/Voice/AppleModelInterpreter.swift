import CoreFoundation
import Foundation
import FoundationModels

/// The small seam around Apple's on-device language model. Tests provide a fake; production never
/// needs a network key or a downloaded third-party interpreter model.
protocol AppleCommandModel: Sendable {
    var isAvailable: Bool { get }
    func propose(_ text: String, toolsJSON: String) async throws -> [ToolCall]
}

struct AppleModelInterpreter: Sendable {
    var model: any AppleCommandModel

    func propose(_ utterance: FinalUtterance, context: ToolContext) async -> [ToolCall]? {
        guard model.isAvailable,
              let data = try? JSONSerialization.data(withJSONObject: ToolCatalog.schema(for: context), options: [.sortedKeys]),
              let toolsJSON = String(data: data, encoding: .utf8),
              let calls = try? await model.propose(utterance.text, toolsJSON: toolsJSON),
              !calls.isEmpty, calls.count <= 5 else { return nil }
        return calls
    }
}

/// The deterministic parser handles its known commands first. Apple's model only proposes calls
/// for otherwise unrecognized wording; every proposal still has to pass the same typed validator
/// and literal-word/number checks that guard the CAD executor.
struct CompositeInterpreter: CommandInterpreter {
    var model: AppleModelInterpreter?
    var fallback: any CommandInterpreter

    func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult {
        if RuleBasedInterpreter.wantsImagine(utterance.text) { return .needsImagine }
        let rules = await fallback.interpret(utterance, context: context)
        guard rules == .clarify(RuleBasedInterpreter.notACommand), let model,
              let calls = await model.propose(utterance, context: context),
              VoiceProposalGuard.accepts(calls, said: utterance.text, context: context) else { return rules }
        return .calls(calls)
    }
}

/// A model may never introduce a value or a tool unrelated to the finished sentence.
enum VoiceProposalGuard {
    static func accepts(_ calls: [ToolCall], said text: String, context: ToolContext) -> Bool {
        guard (try? ToolCatalog.validateSequence(calls, context: context)) != nil else { return false }
        let words = RuleBasedInterpreter.normalise(text)
        let spoken = numbers(in: words)
        for call in calls {
            guard let cues = cues[call.name], words.contains(where: { word in cues.contains { word.hasPrefix($0) } }) else { return false }
            for case .number(let value) in call.arguments.values where !spoken.contains(where: { abs($0 - value) < 1e-9 }) {
                return false
            }
        }
        return true
    }

    private static func numbers(in words: [String]) -> [Double] {
        var found: [Double] = []
        var run: [String] = []
        func flush() {
            if !run.isEmpty, let value = SpokenNumber.parse(run.joined(separator: " ")) { found.append(value) }
            run = []
        }
        for word in words {
            if let digits = Double(word) { flush(); found.append(digits) }
            else if SpokenNumber.isNumberWord(word) { run.append(word) }
            else { flush() }
        }
        flush()
        return found
    }

    private static let cues: [String: [String]] = [
        "create_cube": ["cub"],
        "create_box": ["box", "block", "brick", "cuboid"],
        "create_cylinder": ["cylind", "tube", "rod", "peg", "pipe"],
        "start_sketch": ["sketch", "draw"],
        "add_rectangle": ["rectang", "square", "draw"],
        "add_circle": ["circle", "draw"],
        "add_line": ["line", "draw"],
        "finish_sketch": ["finish", "done", "exit", "close", "leave", "end"],
        "extrude": ["extrud", "pull", "push", "raise", "cut"],
        "resize_selected": ["resiz", "tall", "short", "wide", "narrow", "long", "thick", "thin", "big", "larg", "small", "stretch", "height", "width", "depth", "scale", "increase", "decrease", "make", "set"],
        "move_selected": ["move", "slide", "shift", "push", "nudge", "left", "right", "up", "down", "forward", "back"],
        "rotate_selected": ["rotat", "turn", "spin", "tilt", "degree"],
        "round_selected": ["round", "fillet", "smooth", "bevel", "corner", "edge"],
        "add_hole": ["hole", "drill", "bore", "punch"],
        "duplicate_selected": ["duplic", "copy", "clone"],
        "delete_selected": ["delet", "remov", "eras", "trash"],
        "undo": ["undo", "revert", "back"],
        "redo": ["redo", "restor"],
    ]
}

@available(iOS 27.0, *)
@Generable
private struct AppleToolSelection {
    @Guide(description: "Zero or more CAD tool calls directly requested by the user; use an empty list when unclear")
    var calls: [AppleToolSelectionCall]
}

@available(iOS 27.0, *)
@Generable
private struct AppleToolSelectionCall {
    @Guide(description: "The exact name of a supplied CAD tool")
    var name: String
    @Guide(description: "A JSON object of that tool's arguments, using only quantities the user actually said")
    var argumentsJSON: String
}

/// Uses Apple's system language model for phrases the local rules do not understand. Each request
/// is a fresh session, so unrelated commands cannot leak context into one another.
@available(iOS 27.0, *)
struct AppleFoundationCommandModel: AppleCommandModel {
    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func propose(_ text: String, toolsJSON: String) async throws -> [ToolCall] {
        let session = LanguageModelSession(instructions: """
            You select CAD tools for a finished spoken sentence. Reply with AppleToolSelection.
            Choose only from these tool schemas: \(toolsJSON)
            Use no tool for conversation, unsupported designs, negated actions or uncertainty.
            Never add a dimension or quantity the person did not say. Do not execute tools yourself.
            """)
        let response = try await session.respond(to: text, generating: AppleToolSelection.self)
        return try response.content.calls.map { call in
            let raw = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))
            guard let values = raw as? [String: Any] else { throw AppleToolSelectionError.invalidArguments }
            var arguments: [String: ToolValue] = [:]
            for (key, value) in values {
                if let text = value as? String { arguments[key] = .string(text) }
                else if let number = value as? NSNumber {
                    arguments[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
                } else { throw AppleToolSelectionError.invalidArguments }
            }
            return ToolCall(name: call.name, arguments: arguments)
        }
    }
}

private enum AppleToolSelectionError: Error {
    case invalidArguments
}

enum AppleModelProvider {
    static var interpreter: AppleModelInterpreter? {
        if #available(iOS 27.0, *) {
            AppleModelInterpreter(model: AppleFoundationCommandModel())
        } else {
            nil
        }
    }
}
