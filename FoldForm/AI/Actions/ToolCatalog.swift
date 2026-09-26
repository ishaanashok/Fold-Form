import Foundation

struct ToolParameter {
    enum Kind: String { case number, string }
    var name: String
    var kind: Kind
    var required: Bool
    var detail: String
    var options: [String]? = nil
}

struct ToolSpec {
    enum Availability { case always, sketching, notSketching, selection, canUndo, canRedo }
    var name: String
    var detail: String
    var availability: Availability
    var parameters: [ToolParameter]

    func isAvailable(in context: ToolContext) -> Bool {
        switch availability {
        case .always: true
        case .sketching: context.isSketching
        case .notSketching: !context.isSketching
        case .selection: context.selection != .none
        case .canUndo: context.canUndo
        case .canRedo: context.canRedo
        }
    }
}

/// Every tool the local voice path can run, what it takes, when it is offered, and how a call to it
/// becomes a `CADAction`. Rule-based and model-written calls both pass through `validate`.
enum ToolCatalog {
    /// A new body may be 0.1 mm to 2 m across.
    static let lengthRange: ClosedRange<Float> = 0.0001...2
    /// Matches `SketchController.depthRange` (a test keeps them equal).
    static let extrudeRange: ClosedRange<Float> = 0.002...0.15

    private static let unit = ToolParameter(name: "unit", kind: .string, required: false, detail: "mm, cm, m or in", options: ["mm", "cm", "m", "in"])
    private static let axes = ["x", "y", "z", "width", "height", "depth", "thickness", "length"]

    static let all: [ToolSpec] = [
        ToolSpec(name: "create_cube", detail: "Make, create or add a new cube with equal sides.", availability: .always, parameters: [
            .init(name: "size", kind: .number, required: true, detail: "Side length"), unit]),
        ToolSpec(name: "create_box", detail: "Make, create or add a new rectangular box, block or brick from width, depth and height.", availability: .always, parameters: [
            .init(name: "width", kind: .number, required: true, detail: "Left to right"),
            .init(name: "depth", kind: .number, required: true, detail: "Front to back"),
            .init(name: "height", kind: .number, required: true, detail: "Bottom to top"), unit]),
        ToolSpec(name: "create_cylinder", detail: "Make, create or add a new cylinder, tube, rod or peg with a radius or diameter and a height.", availability: .always, parameters: [
            .init(name: "radius", kind: .number, required: false, detail: "Radius (or give diameter)"),
            .init(name: "diameter", kind: .number, required: false, detail: "Diameter (or give radius)"),
            .init(name: "height", kind: .number, required: true, detail: "Height"), unit]),
        ToolSpec(name: "start_sketch", detail: "Start, begin or open a sketch to draw a 2D outline.", availability: .notSketching, parameters: []),
        ToolSpec(name: "add_rectangle", detail: "Draw or add a rectangle or square to the sketch from its width and height.", availability: .sketching, parameters: [
            .init(name: "width", kind: .number, required: true, detail: "Width"),
            .init(name: "height", kind: .number, required: true, detail: "Height"), unit]),
        ToolSpec(name: "add_circle", detail: "Draw or add a circle to the sketch from its radius or diameter.", availability: .sketching, parameters: [
            .init(name: "radius", kind: .number, required: false, detail: "Radius (or give diameter)"),
            .init(name: "diameter", kind: .number, required: false, detail: "Diameter (or give radius)"), unit]),
        ToolSpec(name: "add_line", detail: "Draw or add a straight line of a given length to the sketch.", availability: .sketching, parameters: [
            .init(name: "length", kind: .number, required: true, detail: "Length"),
            .init(name: "angle", kind: .number, required: false, detail: "Degrees anticlockwise from pointing right"), unit]),
        ToolSpec(name: "finish_sketch", detail: "Finish, close, exit or leave the sketch without extruding.", availability: .sketching, parameters: []),
        ToolSpec(name: "extrude", detail: "Extrude, pull, push or raise the sketched shapes into a solid by a distance, or cut them into the part.", availability: .sketching, parameters: [
            .init(name: "distance", kind: .number, required: true, detail: "How far"), unit,
            .init(name: "operation", kind: .string, required: false, detail: "add (default) or cut", options: ["add", "cut"])]),
        ToolSpec(name: "resize_selected", detail: "Resize, stretch, make taller, wider, longer, thicker or thinner one dimension of the selected part.", availability: .selection, parameters: [
            .init(name: "axis", kind: .string, required: true, detail: "Which dimension", options: axes),
            .init(name: "mode", kind: .string, required: false, detail: "set (default) or add", options: ["set", "add"]),
            .init(name: "value", kind: .number, required: true, detail: "New size, or the amount to add"), unit]),
        ToolSpec(name: "move_selected", detail: "Move, slide, shift or push the selected part in a direction by a distance.", availability: .selection, parameters: [
            .init(name: "direction", kind: .string, required: true, detail: "As seen on screen", options: ["right", "left", "up", "down", "forward", "back"]),
            .init(name: "distance", kind: .number, required: true, detail: "How far"), unit]),
        ToolSpec(name: "rotate_selected", detail: "Rotate, turn, spin or tilt the selected part by an angle.", availability: .selection, parameters: [
            .init(name: "angle", kind: .number, required: true, detail: "Angle"),
            .init(name: "axis", kind: .string, required: false, detail: "x, y (default) or z", options: ["x", "y", "z"]),
            .init(name: "unit", kind: .string, required: false, detail: "degrees (default)", options: ["degrees", "radians"])]),
        ToolSpec(name: "round_selected", detail: "Round, smooth, fillet or bevel the edges and corners of the selected part.", availability: .selection, parameters: [
            .init(name: "radius", kind: .number, required: true, detail: "Corner radius"), unit]),
        ToolSpec(name: "add_hole", detail: "Drill, punch, bore or cut a round hole through the selected part.", availability: .selection, parameters: [
            .init(name: "diameter", kind: .number, required: true, detail: "Hole diameter"), unit]),
        ToolSpec(name: "duplicate_selected", detail: "Duplicate, copy or clone the selected part.", availability: .selection, parameters: []),
        ToolSpec(name: "delete_selected", detail: "Delete, remove, erase or get rid of the selected part.", availability: .selection, parameters: []),
        ToolSpec(name: "undo", detail: "Undo, take back or revert the last change.", availability: .canUndo, parameters: []),
        ToolSpec(name: "redo", detail: "Redo, restore or bring back the change that was just undone.", availability: .canRedo, parameters: []),
    ]

    static func tools(for context: ToolContext) -> [ToolSpec] { all.filter { $0.isAvailable(in: context) } }

    /// The tools in the JSON shape function-calling models expect.
    static func schema(for context: ToolContext) -> [[String: Any]] {
        tools(for: context).map { tool in
            var properties: [String: Any] = [:]
            for p in tool.parameters {
                var entry: [String: Any] = ["type": p.kind.rawValue, "description": p.detail]
                if let options = p.options { entry["enum"] = options }
                properties[p.name] = entry
            }
            let parameters: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": tool.parameters.filter(\.required).map(\.name),
            ]
            return [
                "type": "function",
                "function": ["name": tool.name, "description": tool.detail, "parameters": parameters] as [String: Any],
            ]
        }
    }

    // MARK: Validation

    static func validate(_ call: ToolCall, context: ToolContext) throws -> CADAction {
        guard let spec = all.first(where: { $0.name == call.name }) else { throw ToolError.unknownTool(call.name) }
        guard spec.isAvailable(in: context) else { throw ToolError.notAvailable(unavailableMessage(spec, context)) }
        let args = Args(call: call, context: context)

        switch call.name {
        case "create_cube":
            return .createCube(size: try args.size("size"))
        case "create_box":
            return .createBox(width: try args.size("width"), depth: try args.size("depth"), height: try args.size("height"))
        case "create_cylinder":
            return .createCylinder(radius: try args.radius(), height: try args.size("height"))
        case "start_sketch":
            return .startSketch
        case "add_rectangle":
            return .addRectangle(width: try args.size("width"), height: try args.size("height"))
        case "add_circle":
            return .addCircle(radius: try args.radius())
        case "add_line":
            let length = try args.size("length")
            let angle = try args.optionalNumber("angle") ?? 0
            guard angle.isFinite else { throw ToolError.invalid("Bad angle") }
            let radians = Float(angle) * .pi / 180
            return .addLine(dx: length * cos(radians), dy: length * sin(radians))
        case "finish_sketch":
            return .finishSketch
        case "extrude":
            let distance = try args.size("distance", range: extrudeRange, label: "Extrude distance")
            let operation = try args.optionalString("operation") ?? "add"
            guard ["add", "cut"].contains(operation) else { throw ToolError.invalid("Extrude operation must be add or cut") }
            return .extrude(distance: distance, cut: operation == "cut")
        case "resize_selected":
            guard context.selection != .other else { throw ToolError.notAvailable("This part can't be resized after rotating") }
            let axis = try axisFor(try args.requiredString("axis"))
            let mode: SizeMode = (try args.optionalString("mode") ?? "set") == "add" ? .add : .set
            let value: Float
            if mode == .add {
                value = try args.signedLength("value")
            } else {
                value = try args.size("value")
            }
            return .resize(target: .selected, changes: [DimensionChange(axis: axis, mode: mode, value: value)])
        case "move_selected":
            guard let direction = ViewDirection(rawValue: try args.requiredString("direction")) else {
                throw ToolError.invalid("Direction must be right, left, up, down, forward or back")
            }
            let distance = try args.signedLength("distance")
            guard distance != 0 else { throw ToolError.invalid("Move distance can't be zero") }
            return .move(target: .selected, by: .camera(distance < 0 ? direction.opposite : direction, abs(distance)))
        case "rotate_selected":
            let value = try args.requiredNumber("angle")
            let unit = try args.optionalString("unit") ?? "degrees"
            guard let radians = Quantity.angle(value, unit: unit), radians != 0 else { throw ToolError.invalid("Bad angle") }
            let axisName = try args.optionalString("axis") ?? "y"
            guard let axis = Axis3(rawValue: axisName), [.x, .y, .z].contains(axis) else { throw ToolError.invalid("Axis must be x, y or z") }
            return .rotate(target: .selected, axis: axis, angle: radians)
        case "round_selected":
            return .round(target: .selected, radius: try args.size("radius"))
        case "add_hole":
            return .addHole(target: .selected, diameter: try args.size("diameter"))
        case "duplicate_selected":
            return .duplicate(target: .selected)
        case "delete_selected":
            return .delete(target: .selected)
        case "undo":
            return .undo
        case "redo":
            return .redo
        default:
            throw ToolError.unknownTool(call.name)
        }
    }

    /// Validates calls in order, letting each one change what the next may do (a sketch that was just
    /// started can take shapes, a cube that was just made can be moved).
    static func validateSequence(_ calls: [ToolCall], context: ToolContext) throws -> [CADAction] {
        guard calls.count <= maxCallsPerRequest else { throw ToolError.invalid("That's too many steps at once") }
        var state = context
        var actions: [CADAction] = []
        for call in calls {
            let action = try validate(call, context: state)
            advance(&state, after: action)
            actions.append(action)
        }
        return actions
    }

    static let maxCallsPerRequest = 20

    /// What the context looks like once `action` has run.
    static func advance(_ context: inout ToolContext, after action: CADAction) {
        switch action {
        case .startSketch: context.isSketching = true
        case .finishSketch: context.isSketching = false
        case .extrude(_, let cut):
            context.isSketching = false
            // A new part is selected; a cut adds none.
            if !cut { context.selection = .box }
        case .createCube, .createBox: context.selection = .box
        case .createCylinder: context.selection = .cylinder
        case .createPrism: context.selection = .other
        case .rotate: context.selection = .other
        case .delete: context.selection = .none
        default: break
        }
        switch action {
        case .undo: context.canRedo = true
        case .redo: context.canUndo = true
        default: context.canUndo = true; context.canRedo = false
        }
    }

    /// Why `name` can't run right now, or nil when it can.
    static func availabilityError(for name: String, context: ToolContext) -> ToolError? {
        guard let spec = all.first(where: { $0.name == name }), !spec.isAvailable(in: context) else { return nil }
        return .notAvailable(unavailableMessage(spec, context))
    }

    static func axisFor(_ word: String) throws -> Axis3 {
        switch word.lowercased() {
        case "x", "width", "wide": return .x
        case "y", "height", "tall", "high": return .y
        case "z", "depth", "deep": return .z
        case "thickness", "thick", "thinnest": return .thinnest
        case "length", "long", "longest": return .longest
        default: throw ToolError.invalid("Unknown dimension \(word)")
        }
    }

    private static func unavailableMessage(_ spec: ToolSpec, _ context: ToolContext) -> String {
        switch spec.availability {
        case .selection: "Select a part first"
        case .sketching: "Start a sketch first"
        case .notSketching: "Already sketching"
        case .canUndo: "Nothing to undo"
        case .canRedo: "Nothing to redo"
        case .always: "Not available"
        }
    }

    /// Reads typed values out of a call.
    private struct Args {
        let call: ToolCall
        let context: ToolContext

        func optionalNumber(_ name: String) throws -> Double? {
            switch call.arguments[name] {
            case nil: return nil
            case .number(let v): return v
            case .string(let s):
                if let v = SpokenNumber.parse(s) { return v }
                throw ToolError.invalid("\(name) isn't a number")
            case .bool: throw ToolError.invalid("\(name) isn't a number")
            }
        }

        func requiredNumber(_ name: String) throws -> Double {
            guard let v = try optionalNumber(name) else { throw ToolError.missing(name) }
            guard v.isFinite else { throw ToolError.invalid("\(name) isn't a valid number") }
            return v
        }

        func optionalString(_ name: String) throws -> String? {
            switch call.arguments[name] {
            case nil: return nil
            case .string(let s): return s.lowercased().trimmingCharacters(in: .whitespaces)
            default: throw ToolError.invalid("\(name) must be text")
            }
        }

        func requiredString(_ name: String) throws -> String {
            guard let s = try optionalString(name), !s.isEmpty else { throw ToolError.missing(name) }
            return s
        }

        var unit: String { (try? optionalString("unit")) ?? nil ?? context.defaultUnit }

        /// A length in metres that may be negative (a signed move, or a change to add).
        func signedLength(_ name: String) throws -> Float {
            let value = try requiredNumber(name)
            guard let metres = Quantity.length(value, unit: unit) else { throw ToolError.invalid("Unknown unit \(unit)") }
            return metres
        }

        /// A strictly positive length within `range`.
        func size(_ name: String, range: ClosedRange<Float> = ToolCatalog.lengthRange, label: String? = nil) throws -> Float {
            let metres = try signedLength(name)
            guard metres > 0 else { throw ToolError.invalid("\(label ?? name.capitalized) must be more than zero") }
            guard range.contains(metres) else { throw ToolError.invalid("\(label ?? name.capitalized) is out of range") }
            return metres
        }

        func radius() throws -> Float {
            if call.arguments["radius"] != nil { return try size("radius") }
            if call.arguments["diameter"] != nil { return try size("diameter") / 2 }
            throw ToolError.missing("radius")
        }
    }
}
