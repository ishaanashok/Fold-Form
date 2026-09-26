import Foundation

/// The on-device function-calling model, behind a protocol so the parsing around it is testable and the
/// app still works when the model is missing.
protocol NeedleRuntime: Sendable {
    var isLoaded: Bool { get }
    /// Runs one sentence against this set of tools (OpenAI-style `function` schemas as JSON) and returns
    /// the model's raw JSON reply.
    func generate(prompt: String, toolsJSON: String) async throws -> String
}

enum NeedleProposal: Equatable, Sendable {
    /// Calls to validate; nothing has been checked against the catalogue yet.
    case calls([ToolCall])
    /// The model found no tool that fits, or withheld what it found.
    case empty
    /// No usable answer: not loaded, failed, unparseable or not confident.
    case unusable
}

/// Asks Needle which tools a sentence calls. It only proposes; `CompositeInterpreter` decides whether to
/// trust the proposal.
struct NeedleInterpreter: Sendable {
    let runtime: NeedleRuntime
    /// Below this the engine's own confidence says "confirm" rather than "act", so the answer is not used.
    var minimumConfidence = 0.5

    init(runtime: NeedleRuntime, minimumConfidence: Double = 0.5) {
        self.runtime = runtime
        self.minimumConfidence = minimumConfidence
    }

    func propose(_ utterance: FinalUtterance, context: ToolContext) async -> NeedleProposal {
        guard runtime.isLoaded else { return .unusable }
        guard let tools = try? JSONSerialization.data(withJSONObject: ToolCatalog.schema(for: context), options: [.sortedKeys]),
              let toolsJSON = String(data: tools, encoding: .utf8) else { return .unusable }
        guard let reply = try? await runtime.generate(prompt: utterance.text, toolsJSON: toolsJSON) else { return .unusable }
        return parse(reply)
    }

    func parse(_ reply: String) -> NeedleProposal {
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(reply.utf8)),
              let calls = response.function_calls else { return .unusable }
        if calls.isEmpty { return .empty }
        if let confidence = response.confidence, confidence < minimumConfidence { return .unusable }
        return .calls(calls.map { ToolCall(name: $0.name, arguments: $0.arguments) })
    }

    private struct Response: Decodable {
        var function_calls: [Call]?
        var confidence: Double?
    }

    private struct Call: Decodable {
        var name: String
        var arguments: [String: ToolValue]

        enum CodingKeys: String, CodingKey { case name, arguments }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decodeIfPresent([String: ToolValue].self, forKey: .arguments) ?? [:]
        }
    }
}

extension ToolValue: Decodable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
}

/// The rules first, Needle only for sentences the rules do not recognise. Measured on the shipped base
/// model, Needle often picks a valid but wrong tool for this catalogue ("redo that" became a delete), so
/// it is never allowed to overrule the rules, and its answer must also pass the same catalogue validation
/// as a hand-written call, name a tool that matches something the user said, and use only numbers the
/// user said. Anything less and the user is asked again instead of getting a guess.
struct CompositeInterpreter: CommandInterpreter {
    let needle: NeedleInterpreter?
    let fallback: CommandInterpreter

    func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult {
        // Creative requests belong to Imagine; the local model is never asked to guess at them.
        if RuleBasedInterpreter.wantsImagine(utterance.text) { return .needsImagine }
        let rules = await fallback.interpret(utterance, context: context)
        guard rules == .clarify(RuleBasedInterpreter.notACommand), let needle else { return rules }
        if case .calls(let calls) = await needle.propose(utterance, context: context),
           NeedleGuard.accepts(calls, said: utterance.text, context: context) {
            return .calls(calls)
        }
        return rules
    }
}

/// Checks a model's proposal against what was actually said.
enum NeedleGuard {
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

    /// Every number said, as digits or as words ("twenty five").
    static func numbers(in words: [String]) -> [Double] {
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

    /// Word beginnings that show a sentence is about this tool.
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
