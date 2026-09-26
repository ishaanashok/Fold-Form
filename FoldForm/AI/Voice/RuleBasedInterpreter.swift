import Foundation

/// Turns one spoken sentence into tool calls with plain rules. It is the always-available local
/// interpreter and the fallback when a model is missing. Anything it does not fully understand
/// becomes a question, never a guess.
struct RuleBasedInterpreter: CommandInterpreter {
    func interpret(_ utterance: FinalUtterance, context: ToolContext) async -> InterpretResult {
        Self.parse(utterance.text, context: context)
    }

    static let notACommand = "I didn't catch a command"

    // MARK: Entry point

    static func parse(_ text: String, context: ToolContext) -> InterpretResult {
        let words = normalise(text)
        guard !words.isEmpty else { return .clarify(notACommand) }
        if wantsImagine(words) { return .needsImagine }

        var state = context
        var calls: [ToolCall] = []
        var negated = false
        for clause in clauses(words) {
            if !Set(clause).isDisjoint(with: negations) { negated = true; continue }
            do {
                guard let produced = try handle(items(from: clause), state: state) else { continue }
                for call in produced {
                    let action = try ToolCatalog.validate(call, context: state)
                    ToolCatalog.advance(&state, after: action)
                    calls.append(call)
                }
            } catch let error as Clarify {
                return .clarify(error.message)
            } catch let error as ToolError {
                return .clarify(error.message)
            } catch {
                return .clarify(notACommand)
            }
        }
        if !calls.isEmpty { return .calls(calls) }
        return .clarify(negated ? "Nothing to do" : notACommand)
    }

    private struct Clarify: Error { let message: String }

    // MARK: Words

    private static let negations: Set<String> = ["not", "dont", "never"]
    private static let fillers: Set<String> = ["please", "now", "also", "just", "kindly"]
    private static let verbs: Set<String> = [
        "move", "shift", "slide", "nudge", "rotate", "turn", "spin", "extrude", "cut", "create", "make", "add", "draw",
        "build", "place", "round", "fillet", "delete", "remove", "duplicate", "copy", "clone", "undo", "redo", "finish",
        "start", "begin", "set", "change", "resize", "drill", "adjust",
    ]
    private static let imagineWords: Set<String> = [
        "design", "handle", "bracket", "stand", "holder", "enclosure", "generate", "imagine", "ventilation", "slots",
        "slot", "backrest",
    ]
    private static let designedObjects: Set<String> = [
        "table", "chair", "desk", "stool", "bench", "bookcase", "bookshelf", "shelf", "cabinet",
    ]
    private static let angleUnits: Set<String> = ["degrees", "degree", "deg", "radians", "radian", "rad"]
    private static let nounKinds: [String: String] = [
        "cube": "cube", "box": "box", "block": "box", "cuboid": "box", "cylinder": "cylinder", "circle": "circle",
        "rectangle": "rectangle", "square": "rectangle", "line": "line",
    ]
    private static let creationVerbs: Set<String> = ["create", "make", "add", "draw", "build", "place", "new"]
    private static let determiners: Set<String> = ["a", "an", "another", "new"]
    private static let pronouns: Set<String> = ["this", "it", "that", "these", "those"]
    private static let directions: [String: String] = [
        "right": "right", "left": "left", "up": "up", "upward": "up", "upwards": "up", "down": "down",
        "downward": "down", "downwards": "down", "forward": "forward", "forwards": "forward", "back": "back",
        "backward": "back", "backwards": "back",
    ]
    private static let dimensionLabels: [String: String] = [
        "radius": "radius", "diameter": "diameter", "height": "height", "tall": "height", "high": "height",
        "width": "width", "wide": "width", "depth": "depth", "deep": "depth", "thickness": "thickness",
        "thick": "thickness", "length": "length", "long": "length",
    ]
    private static let comparatives: [String: (axis: String, sign: Double)] = [
        "taller": ("height", 1), "shorter": ("height", -1), "wider": ("width", 1), "narrower": ("width", -1),
        "thicker": ("thickness", 1), "thinner": ("thickness", -1), "longer": ("length", 1), "deeper": ("depth", 1),
    ]

    /// Whether this sentence asks for something creative that only Imagine should attempt.
    static func wantsImagine(_ text: String) -> Bool { wantsImagine(normalise(text)) }

    private static func wantsImagine(_ words: [String]) -> Bool {
        if !Set(words).isDisjoint(with: imagineWords) { return true }
        if let verb = words.firstIndex(where: creationVerbs.contains),
           let determiner = words[(verb + 1)...].firstIndex(where: determiners.contains),
           words[(determiner + 1)...].contains(where: designedObjects.contains) { return true }
        for (a, b) in zip(words, words.dropFirst()) where a == "into" && (b == "a" || b == "an") { return true }
        return false
    }

    /// Lower-cases, splits numbers from their units, and turns sentence breaks into "|" words.
    static func normalise(_ text: String) -> [String] {
        var s = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("(?<=\\d)\"", " inches ")
        s = s.replacingOccurrences(of: "\"", with: " ")
        s = s.replacingOccurrences(of: "°", with: " degrees ")
        s = s.replacingOccurrences(of: "×", with: " by ")
        sub("(?<=\\d)\\s*x\\s*(?=\\d)", " by ")
        sub("(?<!\\d)\\.|\\.(?!\\d)", " | ")
        sub("[,;:!?]", " | ")
        sub("-(?!\\d)", " ")
        sub("(?<=[a-z0-9])-(?=\\d)", " ")
        sub("(\\d)([a-z])", "$1 $2")
        s = s.replacingOccurrences(of: "'", with: "")
        return s.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !fillers.contains($0) }
    }

    /// Splits at "then", and at "and" or a sentence break when a new command follows.
    private static func clauses(_ words: [String]) -> [[String]] {
        let connectors: Set<String> = ["|", "and", "then"]
        var result: [[String]] = []
        var current: [String] = []
        var i = 0
        while i < words.count {
            guard connectors.contains(words[i]) else { current.append(words[i]); i += 1; continue }
            var j = i
            while j < words.count, connectors.contains(words[j]) { j += 1 }
            let run = words[i..<j]
            let startsCommand = j < words.count && verbs.contains(words[j])
            if run.contains("then") || startsCommand {
                if !current.isEmpty { result.append(current) }
                current = []
            } else {
                current.append(contentsOf: run.filter { $0 != "|" })
            }
            i = j
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Quantities

    private struct Qty {
        var value: Double
        var unit: String?
        var isAngle: Bool { unit.map { RuleBasedInterpreter.angleUnits.contains($0) } ?? false }
        var isLength: Bool { unit == nil || Quantity.isLengthUnit(unit!) }
    }

    private enum Item {
        case qty(Qty)
        case word(String)

        var word: String? { if case .word(let w) = self { w } else { nil } }
        var qty: Qty? { if case .qty(let q) = self { q } else { nil } }
    }

    private static func isDigits(_ token: String) -> Bool {
        token.range(of: "^-?\\d*\\.?\\d+$", options: .regularExpression) != nil
    }

    private static let unitBlockers: Set<String> = ["the", "a", "an", "diameter", "width", "height", "length", "radius", "size", "front", "this", "that"]

    private static func isUnit(_ word: String, next: String?) -> Bool {
        if word == "in" { return !(next.map(unitBlockers.contains) ?? false) }
        return Quantity.isLengthUnit(word) || angleUnits.contains(word)
    }

    /// A number spelled out in words, starting at `start`: how many words it took and its value.
    private static func numberRun(_ words: [String], _ start: Int) -> (value: Double, count: Int)? {
        var j = start
        var tokens: [String] = []
        if words[j] == "minus" || words[j] == "negative" { tokens.append(words[j]); j += 1 }
        var sawNumber = false
        while j < words.count {
            let w = words[j]
            if SpokenNumber.isNumberWord(w) {
                sawNumber = true
            } else if w == "point", sawNumber, j + 1 < words.count, SpokenNumber.isNumberWord(words[j + 1]) || isDigits(words[j + 1]) {
                // decimal part follows
            } else if w == "and", tokens.last == "hundred", j + 1 < words.count, SpokenNumber.isNumberWord(words[j + 1]) {
                // "one hundred and twenty"
            } else if w == "a", tokens.isEmpty, j + 1 < words.count, words[j + 1] == "hundred" {
                // "a hundred"
            } else {
                break
            }
            tokens.append(w)
            j += 1
        }
        guard sawNumber else { return nil }
        // "this one" is a pronoun, not the number 1.
        if tokens == ["one"], !(j < words.count && (isUnit(words[j], next: nil) || words[j] == "by")) { return nil }
        guard let value = SpokenNumber.parse(tokens.joined(separator: " ")) else { return nil }
        return (value, j - start)
    }

    private static func items(from words: [String]) -> [Item] {
        var out: [Item] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            var value: Double?
            var consumed = 0
            if isDigits(w), let v = Double(w) {
                (value, consumed) = (v, 1)
            } else if w == "minus" || w == "negative", i + 1 < words.count, isDigits(words[i + 1]), let v = Double(words[i + 1]) {
                (value, consumed) = (-v, 2)
            } else if let run = numberRun(words, i) {
                (value, consumed) = (run.value, run.count)
            }
            guard let v = value else { out.append(.word(w)); i += 1; continue }
            var unit: String?
            let next = i + consumed
            if next < words.count, isUnit(words[next], next: next + 1 < words.count ? words[next + 1] : nil) {
                unit = words[next]
                consumed += 1
            }
            out.append(.qty(Qty(value: v, unit: unit)))
            i += consumed
        }
        return out
    }

    /// The word that says what a quantity measures: "radius of 12 mm" (before) or "20 mm in diameter" (after).
    private static func label(of index: Int, in items: [Item]) -> String? {
        let stops: Set<String> = ["and", "by"]
        var i = index - 1
        while i >= 0, index - i <= 3 {
            if items[i].qty != nil { break }
            if let w = items[i].word {
                if stops.contains(w) { break }
                if let label = dimensionLabels[w] { return label }
            }
            i -= 1
        }
        i = index + 1
        while i < items.count, i - index <= 3 {
            if items[i].qty != nil { break }
            if let w = items[i].word {
                if stops.contains(w) { break }
                if let label = dimensionLabels[w] { return label }
            }
            i += 1
        }
        return nil
    }

    /// Quantities joined by "by" ("20 by 40 by 5 mm"), each given the unit that ends the chain.
    private static func chain(in items: [Item]) -> [Qty]? {
        var i = 0
        while i < items.count {
            guard items[i].qty != nil else { i += 1; continue }
            var run: [Qty] = [items[i].qty!]
            var j = i + 1
            while j + 1 < items.count, items[j].word == "by", let q = items[j + 1].qty {
                run.append(q)
                j += 2
            }
            if run.count >= 2 {
                var unit: String?
                for k in run.indices.reversed() {
                    if let u = run[k].unit { unit = u } else { run[k].unit = unit }
                }
                return run
            }
            i = j
        }
        return nil
    }

    private static func lengths(_ items: [Item]) -> [Qty] { items.compactMap(\.qty).filter(\.isLength) }

    /// Number arguments for `names`, in one unit (converted through metres when the units differ).
    private static func args(_ names: [String], _ quantities: [Qty]) -> [String: ToolValue] {
        var result: [String: ToolValue] = [:]
        let units = Set(quantities.compactMap(\.unit))
        if units.count > 1 {
            for (name, q) in zip(names, quantities) {
                let metres = q.unit.flatMap { Quantity.length(q.value, unit: $0) }.map(Double.init) ?? q.value
                result[name] = .number(metres)
            }
            result["unit"] = .string("m")
        } else {
            for (name, q) in zip(names, quantities) { result[name] = .number(q.value) }
            if let unit = units.first { result["unit"] = .string(unit) }
        }
        return result
    }

    // MARK: Intents

    private static func need(_ tool: String, _ state: ToolContext) throws {
        if let error = ToolCatalog.availabilityError(for: tool, context: state) { throw error }
    }

    private static func handle(_ items: [Item], state: ToolContext) throws -> [ToolCall]? {
        let words = items.compactMap(\.word)
        let set = Set(words)
        func has(_ candidates: String...) -> Bool { candidates.contains { set.contains($0) } }

        if has("chamfer", "chamfers", "chamfered") {
            throw Clarify(message: "Chamfers aren't supported yet. I can round the edges instead.")
        }
        if has("undo") { return [ToolCall(name: "undo")] }
        if has("redo") { return [ToolCall(name: "redo")] }
        if has("sketch") {
            if has("finish", "end", "close", "done", "exit") { return [ToolCall(name: "finish_sketch")] }
            if has("start", "begin", "open", "new") { return [ToolCall(name: "start_sketch")] }
        }
        for (a, b) in zip(words, words.dropFirst()) where b == "hole" && ["this", "that", "the", "these", "existing"].contains(a) {
            throw Clarify(message: "Changing an existing hole isn't supported yet. Add a new hole instead.")
        }
        if has("hole") { return try hole(items, state) }
        if let noun = creationNoun(words) { return try create(noun, items, state) }
        if has("extrude") || words.first == "cut" || has("pull") { return try extrude(items, state) }
        if has("move", "shift", "slide", "nudge") { return try move(items, state) }
        if has("rotate", "turn", "spin") { return try rotate(items, state) }
        if has("round", "fillet", "smooth") { return try round(items, state) }
        if has("duplicate", "copy", "clone") { try need("duplicate_selected", state); return [ToolCall(name: "duplicate_selected")] }
        if has("delete", "remove", "erase", "discard") { try need("delete_selected", state); return [ToolCall(name: "delete_selected")] }
        if set.contains(where: { comparatives[$0] != nil }) || (has("make", "set", "change", "resize", "adjust") && lengthNounOrAdjective(items)) {
            return try resize(items, state)
        }
        return nil
    }

    private static func lengthNounOrAdjective(_ items: [Item]) -> Bool {
        items.contains { $0.qty != nil } && items.contains { $0.word.map { dimensionLabels[$0] != nil } ?? false }
    }

    /// The thing being made ("cube", "circle"), when a creation verb is followed by "a"/"an"/"another".
    private static func creationNoun(_ words: [String]) -> String? {
        guard let verb = words.firstIndex(where: creationVerbs.contains) else { return nil }
        var sawDeterminer = false
        for w in words[(verb + 1)...] {
            if pronouns.contains(w) { return nil }
            if determiners.contains(w) { sawDeterminer = true }
            if let kind = nounKinds[w], sawDeterminer { return kind }
        }
        return nil
    }

    private static func create(_ noun: String, _ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        let sizes = lengths(items)
        switch noun {
        case "cube":
            guard let q = sizes.first else { throw Clarify(message: "How big should the cube be?") }
            return [ToolCall(name: "create_cube", arguments: args(["size"], [q]))]
        case "box":
            guard let dims = chain(in: items), dims.count == 3 else { throw Clarify(message: "Give the box three sizes, like 20 by 40 by 5.") }
            return [ToolCall(name: "create_box", arguments: args(["width", "depth", "height"], dims))]
        case "cylinder":
            var radius: [String: ToolValue] = [:]
            var height: Qty?
            var round: Qty?
            var isDiameter = false
            for (index, item) in items.enumerated() {
                guard let q = item.qty, q.isLength else { continue }
                switch label(of: index, in: items) {
                case "radius": round = q
                case "diameter": round = q; isDiameter = true
                case "height": height = q
                default: break
                }
            }
            guard let round, let height else { throw Clarify(message: "Give the cylinder a radius and a height.") }
            radius = args([isDiameter ? "diameter" : "radius", "height"], [round, height])
            return [ToolCall(name: "create_cylinder", arguments: radius)]
        case "circle", "rectangle", "line":
            var calls: [ToolCall] = []
            if !state.isSketching { calls.append(ToolCall(name: "start_sketch")) }
            calls.append(try shape(noun, items))
            return calls
        default:
            return []
        }
    }

    private static func shape(_ noun: String, _ items: [Item]) throws -> ToolCall {
        let sizes = lengths(items)
        switch noun {
        case "circle":
            guard let index = items.firstIndex(where: { $0.qty?.isLength == true }), let q = items[index].qty else {
                throw Clarify(message: "How big should the circle be?")
            }
            // A bare "12 millimeter circle" is read as the width across, the way people say it.
            let name = label(of: index, in: items) == "radius" ? "radius" : "diameter"
            return ToolCall(name: "add_circle", arguments: args([name], [q]))
        case "rectangle":
            if let dims = chain(in: items), dims.count == 2 {
                return ToolCall(name: "add_rectangle", arguments: args(["width", "height"], dims))
            }
            if let q = sizes.first { return ToolCall(name: "add_rectangle", arguments: args(["width", "height"], [q, q])) }
            throw Clarify(message: "Give the rectangle two sizes, like 4 by 6.")
        default:
            guard let q = sizes.first else { throw Clarify(message: "How long should the line be?") }
            var arguments = args(["length"], [q])
            if let angle = items.compactMap(\.qty).first(where: \.isAngle) { arguments["angle"] = .number(angle.value) }
            return ToolCall(name: "add_line", arguments: arguments)
        }
    }

    private static func extrude(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("extrude", state)
        guard let q = lengths(items).first else { throw Clarify(message: "How far?") }
        var arguments = args(["distance"], [q])
        if items.contains(where: { $0.word == "cut" }) { arguments["operation"] = .string("cut") }
        return [ToolCall(name: "extrude", arguments: arguments)]
    }

    private static func move(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("move_selected", state)
        guard let direction = items.compactMap({ $0.word.flatMap { directions[$0] } }).first else { throw Clarify(message: "Which direction?") }
        guard let q = lengths(items).first else { throw Clarify(message: "How far?") }
        var arguments = args(["distance"], [q])
        arguments["direction"] = .string(direction)
        return [ToolCall(name: "move_selected", arguments: arguments)]
    }

    private static func rotate(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("rotate_selected", state)
        let angles = items.compactMap(\.qty).filter { $0.isAngle || $0.unit == nil }
        guard let q = angles.first, let index = items.firstIndex(where: { $0.qty != nil && $0.qty!.value == q.value && $0.qty!.unit == q.unit }) else {
            throw Clarify(message: "How many degrees?")
        }
        var arguments: [String: ToolValue] = ["angle": .number(q.value)]
        arguments["unit"] = .string(q.unit.map { $0.hasPrefix("rad") ? "radians" : "degrees" } ?? "degrees")
        if let axis = items[index...].compactMap(\.word).first(where: { ["x", "y", "z"].contains($0) }) {
            arguments["axis"] = .string(axis)
        }
        return [ToolCall(name: "rotate_selected", arguments: arguments)]
    }

    private static func round(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("round_selected", state)
        guard let q = lengths(items).first else { throw Clarify(message: "How much rounding?") }
        return [ToolCall(name: "round_selected", arguments: args(["radius"], [q]))]
    }

    private static func hole(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("add_hole", state)
        guard let index = items.firstIndex(where: { $0.qty?.isLength == true }), var q = items[index].qty else {
            throw Clarify(message: "How wide should the hole be?")
        }
        if label(of: index, in: items) == "radius" { q.value *= 2 }
        return [ToolCall(name: "add_hole", arguments: args(["diameter"], [q]))]
    }

    private static func resize(_ items: [Item], _ state: ToolContext) throws -> [ToolCall] {
        try need("resize_selected", state)
        if let comparative = items.compactMap({ $0.word.flatMap { comparatives[$0] } }).first {
            guard let q = lengths(items).first else { throw Clarify(message: "By how much?") }
            var arguments = args(["value"], [Qty(value: q.value * comparative.sign, unit: q.unit)])
            arguments["axis"] = .string(comparative.axis)
            arguments["mode"] = .string("add")
            return [ToolCall(name: "resize_selected", arguments: arguments)]
        }
        for (index, item) in items.enumerated() {
            guard let q = item.qty, q.isLength, let axis = label(of: index, in: items), axis != "radius", axis != "diameter" else { continue }
            var arguments = args(["value"], [q])
            arguments["axis"] = .string(axis)
            arguments["mode"] = .string("set")
            return [ToolCall(name: "resize_selected", arguments: arguments)]
        }
        throw Clarify(message: "Which dimension?")
    }
}
