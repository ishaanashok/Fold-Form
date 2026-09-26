import Foundation

/// Every unit conversion for voice and Imagine happens here, in the app, never in a model.
/// Lengths come out in metres (the scene unit) and angles in radians.
enum Quantity {
    private static let metresPerUnit: [String: Float] = {
        var table: [String: Float] = [:]
        for name in ["mm", "millimeter", "millimeters", "millimetre", "millimetres"] { table[name] = 0.001 }
        for name in ["cm", "centimeter", "centimeters", "centimetre", "centimetres"] { table[name] = 0.01 }
        for name in ["m", "meter", "meters", "metre", "metres"] { table[name] = 1 }
        for name in ["in", "inch", "inches", "\""] { table[name] = 0.0254 }
        return table
    }()

    /// Whether `word` names a length unit.
    static func isLengthUnit(_ word: String) -> Bool { metresPerUnit[word.lowercased()] != nil }

    static func length(_ value: Double, unit: String) -> Float? {
        guard value.isFinite, let scale = metresPerUnit[unit.lowercased().trimmingCharacters(in: .whitespaces)] else { return nil }
        let result = Float(value) * scale
        return result.isFinite ? result : nil
    }

    static func angle(_ value: Double, unit: String) -> Float? {
        guard value.isFinite else { return nil }
        switch unit.lowercased().trimmingCharacters(in: .whitespaces) {
        case "degrees", "degree", "deg", "°": return Float(value) * .pi / 180
        case "radians", "radian", "rad": return Float(value)
        default: return nil
        }
    }
}

/// Reads a number the way it is spoken or typed: "three", "twenty five", "two point five", "3.5",
/// "minus ten". Anything it does not fully understand gives nil rather than a guess.
enum SpokenNumber {
    private static let ones: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let negatives: Set<String> = ["minus", "negative"]

    static func parse(_ text: String) -> Double? {
        let cleaned = text.lowercased().replacingOccurrences(of: "-", with: " ", options: [], range: nil)
        var words = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // A leading "-" was turned into a space above; restore a plain negative like "-2.5".
        var negative = false
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("-"), let first = words.first, Double(first) != nil {
            negative = true
        }
        if let first = words.first, negatives.contains(first) { negative = true; words.removeFirst() }
        guard !words.isEmpty else { return nil }

        var total = 0.0, current = 0.0
        var sawNumber = false
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "and" { continue }
            if word == "a" || word == "an" {
                guard index < words.count, words[index] == "hundred" else { return nil }
                current = 1
                continue
            }
            if word == "point" {
                var fraction = 0.0, place = 0.1
                guard index < words.count else { return nil }
                while index < words.count {
                    let digit = words[index]
                    let value: Double
                    if let d = ones[digit], d < 10 { value = d }
                    else if digit.count == 1, let d = Double(digit) { value = d }
                    else { return nil }
                    fraction += value * place
                    place /= 10
                    index += 1
                }
                let result = total + current + fraction
                return negative ? -result : result
            }
            if word == "hundred" {
                current = (current == 0 ? 1 : current) * 100
                sawNumber = true
                continue
            }
            if let value = ones[word] ?? tens[word] {
                current += value
                sawNumber = true
                continue
            }
            if let value = Double(word), value.isFinite {
                current += value
                sawNumber = true
                continue
            }
            return nil
        }
        guard sawNumber else { return nil }
        total += current
        return negative ? -total : total
    }
}
