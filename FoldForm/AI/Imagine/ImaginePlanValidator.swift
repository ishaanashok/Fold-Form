import Foundation
import simd

enum ImagineValidationError: Error, Equatable {
    case unknownOperation(String)
    case missing(String)
    case invalidNumber(String)
    case invalidArgument(String)
    case badUnit(String)
    case unknownReference(String)
    case forwardReference(String)
    case tooManySteps
    case staleRevision
    case forbiddenDelete
    case basePlateDelete

    var message: String {
        switch self {
        case .unknownOperation(let op): "Unsupported operation: \(op)"
        case .missing(let field): "Missing \(field)"
        case .invalidNumber(let field): "Invalid number for \(field)"
        case .invalidArgument(let field): "Invalid \(field)"
        case .badUnit(let unit): "Unsupported unit: \(unit)"
        case .unknownReference(let target): "Unknown part: \(target)"
        case .forwardReference(let target): "Part \(target) was used before it was created"
        case .tooManySteps: "The plan has too many steps"
        case .staleRevision: "The design changed while Imagine was planning. Generate again."
        case .forbiddenDelete: "Deleting a part requires an explicit request"
        case .basePlateDelete: "The base plate can't be deleted"
        }
    }
}

/// Converts untrusted model output to the same typed actions used by voice. It does no mutation.
enum ImaginePlanValidator {
    static func validate(_ plan: ImaginePlan, bodyCount: Int, revision: Int, currentRevision: Int, allowDelete: Bool) throws -> [CADAction] {
        guard revision == currentRevision else { throw ImagineValidationError.staleRevision }
        guard plan.steps.count <= 12 else { throw ImagineValidationError.tooManySteps }
        var made: Set<String> = []
        let future = Set(plan.steps.compactMap(\.as))
        var actions: [CADAction] = []
        for step in plan.steps {
            let args = Arguments(step.args)
            let action: CADAction
            switch step.op {
            case "add_box":
                action = .createBox(width: try args.size("width"), depth: try args.size("depth"), height: try args.size("height"), at: try args.placement(), name: step.as)
            case "add_cylinder":
                let radius: Float
                if step.args["radius"] != nil { radius = try args.size("radius") }
                else { radius = try args.size("diameter") / 2 }
                action = .createCylinder(radius: radius, height: try args.size("height"), at: try args.placement(), name: step.as)
            case "extrude_profile":
                let points = try args.outline()
                let depth = try args.size("depth", range: ToolCatalog.extrudeRange)
                action = .createPrism(outline: points, depth: depth, at: try args.placement(), name: step.as)
            case "move":
                action = .move(target: try reference(step.target, bodyCount: bodyCount, made: made, future: future), by: .world(try args.offset()))
            case "resize":
                let target = try reference(step.target, bodyCount: bodyCount, made: made, future: future)
                let axisName = try args.string("axis")
                let axis: Axis3
                do { axis = try ToolCatalog.axisFor(axisName) }
                catch { throw ImagineValidationError.invalidArgument("axis") }
                let modeName = try args.string("mode")
                guard modeName == "set" || modeName == "add" else { throw ImagineValidationError.invalidArgument("mode") }
                let mode: SizeMode = modeName == "add" ? .add : .set
                let value = try args.length("value", positive: mode == .set)
                action = .resize(target: target, changes: [.init(axis: axis, mode: mode, value: value)])
            case "rotate":
                let target = try reference(step.target, bodyCount: bodyCount, made: made, future: future)
                let axisName = try args.string("axis")
                guard let axis = Axis3(rawValue: axisName), [.x, .y, .z].contains(axis) else { throw ImagineValidationError.invalidArgument("axis") }
                let unit = try args.string("unit", default: "degrees")
                let number = try args.number("angle")
                guard let angle = Quantity.angle(number, unit: unit), angle.isFinite, angle != 0, abs(angle) <= 2 * .pi else { throw ImagineValidationError.invalidNumber("angle") }
                action = .rotate(target: target, axis: axis, angle: angle)
            case "round":
                action = .round(target: try reference(step.target, bodyCount: bodyCount, made: made, future: future), radius: try args.size("radius"))
            case "add_hole":
                action = .addHole(target: try reference(step.target, bodyCount: bodyCount, made: made, future: future), diameter: try args.size("diameter"))
            case "delete":
                guard allowDelete else { throw ImagineValidationError.forbiddenDelete }
                let target = try reference(step.target, bodyCount: bodyCount, made: made, future: future)
                guard target != .existing(0) else { throw ImagineValidationError.basePlateDelete }
                action = .delete(target: target)
            default:
                throw ImagineValidationError.unknownOperation(step.op)
            }
            if let name = step.as {
                guard !name.isEmpty, name.count <= 32, name.first?.isLetter == true,
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                      !name.hasPrefix("P"), !made.contains(name),
                      ["add_box", "add_cylinder", "extrude_profile"].contains(step.op) else {
                    throw ImagineValidationError.invalidArgument("as")
                }
                made.insert(name)
            }
            actions.append(action)
        }
        return actions
    }

    private static func reference(_ text: String?, bodyCount: Int, made: Set<String>, future: Set<String>) throws -> BodyTarget {
        guard let text, !text.isEmpty else { throw ImagineValidationError.missing("target") }
        if text.hasPrefix("P"), let index = Int(text.dropFirst()), index >= 0 {
            guard index < bodyCount else { throw ImagineValidationError.unknownReference(text) }
            return .existing(index)
        }
        if made.contains(text) { return .named(text) }
        if future.contains(text) { throw ImagineValidationError.forwardReference(text) }
        throw ImagineValidationError.unknownReference(text)
    }

    private struct Arguments {
        let values: [String: ImagineValue]
        init(_ values: [String: ImagineValue]) { self.values = values }

        func number(_ key: String, default defaultValue: Double? = nil) throws -> Double {
            guard let value = values[key] else {
                if let defaultValue { return defaultValue }
                throw ImagineValidationError.missing(key)
            }
            guard case .number(let number) = value, number.isFinite else { throw ImagineValidationError.invalidNumber(key) }
            return number
        }

        func string(_ key: String, default defaultValue: String? = nil) throws -> String {
            guard let value = values[key] else {
                if let defaultValue { return defaultValue }
                throw ImagineValidationError.missing(key)
            }
            guard case .string(let text) = value, !text.isEmpty else { throw ImagineValidationError.invalidArgument(key) }
            return text
        }

        func unit() throws -> String {
            let unit = try string("unit", default: "mm")
            guard Quantity.length(1, unit: unit) != nil else { throw ImagineValidationError.badUnit(unit) }
            return unit
        }

        func length(_ key: String, positive: Bool = false) throws -> Float {
            let value = try number(key)
            guard let metres = Quantity.length(value, unit: try unit()), metres.isFinite,
                  abs(metres) <= ToolCatalog.lengthRange.upperBound,
                  (!positive || metres >= ToolCatalog.lengthRange.lowerBound) else {
                throw ImagineValidationError.invalidNumber(key)
            }
            return metres
        }

        func size(_ key: String, range: ClosedRange<Float> = ToolCatalog.lengthRange) throws -> Float {
            let metres = try length(key, positive: true)
            guard range.contains(metres) else { throw ImagineValidationError.invalidNumber(key) }
            return metres
        }

        func offset() throws -> SIMD3<Float> {
            let x = try component("x")
            let y = try component("y")
            let z = try component("z")
            guard x != 0 || y != 0 || z != 0 else { throw ImagineValidationError.invalidNumber("offset") }
            return [x, y, z]
        }

        func placement() throws -> Placement {
            guard ["x", "y", "z"].contains(where: { values[$0] != nil }) else { return .beside }
            return .fromCentre([try component("x"), try component("y"), try component("z")])
        }

        private func component(_ key: String) throws -> Float {
            guard values[key] != nil else { return 0 }
            return try length(key)
        }

        func outline() throws -> [SIMD2<Float>] {
            guard let value = values["outline"] else { throw ImagineValidationError.missing("outline") }
            guard case .array(let rawPoints) = value, (3...64).contains(rawPoints.count) else { throw ImagineValidationError.invalidArgument("outline") }
            let unit = try unit()
            let points = try rawPoints.map { point -> SIMD2<Float> in
                guard case .array(let pair) = point, pair.count == 2,
                      case .number(let x) = pair[0], case .number(let y) = pair[1],
                      let mx = Quantity.length(x, unit: unit), let my = Quantity.length(y, unit: unit),
                      mx.isFinite, my.isFinite, abs(mx) <= 2, abs(my) <= 2 else { throw ImagineValidationError.invalidArgument("outline") }
                return [mx, my]
            }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  maxX - minX >= 0.002, maxY - minY >= 0.002 else { throw ImagineValidationError.invalidArgument("outline") }
            return points
        }
    }
}
