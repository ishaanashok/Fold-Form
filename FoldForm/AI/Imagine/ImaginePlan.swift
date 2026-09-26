import Foundation

/// A bounded proposal from Imagine. Decoding does not make any step safe to execute.
struct ImaginePlan: Codable, Equatable {
    var assumptions: [ImagineAssumption]
    var steps: [ImagineStep]

    init(assumptions: [ImagineAssumption], steps: [ImagineStep]) {
        self.assumptions = assumptions
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assumptions = try container.decodeIfPresent([ImagineAssumption].self, forKey: .assumptions) ?? []
        steps = try container.decode([ImagineStep].self, forKey: .steps)
    }

    static func decode(_ data: Data) throws -> ImaginePlan {
        guard let text = String(data: data, encoding: .utf8) else { throw ImaginePlanError.unreadable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            guard let newline = trimmed.firstIndex(of: "\n"), trimmed.hasSuffix("```") else { throw ImaginePlanError.unreadable }
            json = String(trimmed[trimmed.index(after: newline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
        } else {
            json = trimmed
        }
        return try JSONDecoder().decode(ImaginePlan.self, from: Data(json.utf8))
    }
}

struct ImagineAssumption: Codable, Equatable {
    var name: String
    var value: String
    var unit: String
}

struct ImagineStep: Codable, Equatable {
    var `as`: String?
    var op: String
    var args: [String: ImagineValue]
    var target: String?

    init(as name: String?, op: String, args: [String: ImagineValue], target: String?) {
        self.as = name
        self.op = op
        self.args = args
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        `as` = try container.decodeIfPresent(String.self, forKey: .as)
        op = try container.decode(String.self, forKey: .op)
        args = try container.decodeIfPresent([String: ImagineValue].self, forKey: .args) ?? [:]
        target = try container.decodeIfPresent(String.self, forKey: .target)
    }
}

indirect enum ImagineValue: Codable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([ImagineValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else { self = .array(try value.decode([ImagineValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .bool(let bool): try value.encode(bool)
        case .array(let array): try value.encode(array)
        }
    }
}

enum ImaginePlanError: Error { case unreadable }
