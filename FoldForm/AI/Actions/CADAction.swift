import Foundation
import simd

/// A loosely typed argument, the way a model or the rule-based interpreter hands it over.
enum ToolValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
}

/// A request to run one named tool. Nothing here is trusted until `ToolCatalog.validate` accepts it.
struct ToolCall: Equatable, Sendable {
    var name: String
    var arguments: [String: ToolValue]

    init(name: String, arguments: [String: ToolValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

/// A world axis, or one picked by the size of the part it is applied to.
enum Axis3: String, Equatable {
    case x, y, z, thinnest, longest
}

enum SizeMode: Equatable { case set, add }

struct DimensionChange: Equatable {
    var axis: Axis3
    var mode: SizeMode
    /// Metres.
    var value: Float
}

/// Directions as the user sees them; the executor turns them into the world axis nearest the camera's.
enum ViewDirection: String, Equatable {
    case right, left, up, down, forward, back

    var opposite: ViewDirection {
        switch self {
        case .right: .left
        case .left: .right
        case .up: .down
        case .down: .up
        case .forward: .back
        case .back: .forward
        }
    }
}

enum Displacement: Equatable {
    /// Along the world axis nearest to what the user calls right, up or forward on screen. Metres.
    case camera(ViewDirection, Float)
    /// A world-axis offset in metres (used by Imagine plans).
    case world(SIMD3<Float>)
}

/// Which body an edit applies to.
enum BodyTarget: Equatable {
    /// The part the user has selected.
    case selected
    /// A body of the design as it was when a request was made (`P0`, `P1`, …), plate first.
    case existing(Int)
    /// A body an earlier step of the same plan made.
    case named(String)
}

/// Where a new body goes.
enum Placement: Equatable {
    /// To the right of everything already there, on the same base.
    case beside
    /// With its centre this far (metres, world axes) from the middle of the current design.
    case fromCentre(SIMD3<Float>)
}

/// The one vocabulary every input method ends in. Lengths are metres and angles radians.
enum CADAction: Equatable {
    case createCube(size: Float, at: Placement = .beside, name: String? = nil)
    case createBox(width: Float, depth: Float, height: Float, at: Placement = .beside, name: String? = nil)
    case createCylinder(radius: Float, height: Float, at: Placement = .beside, name: String? = nil)
    /// A profile in the x-y plane extruded `depth` along z, centred on its own middle.
    case createPrism(outline: [SIMD2<Float>], depth: Float, at: Placement = .beside, name: String? = nil)
    case startSketch
    case addRectangle(width: Float, height: Float)
    case addCircle(radius: Float)
    case addLine(dx: Float, dy: Float)
    case finishSketch
    case extrude(distance: Float, cut: Bool)
    case resize(target: BodyTarget, changes: [DimensionChange])
    case move(target: BodyTarget, by: Displacement)
    case rotate(target: BodyTarget, axis: Axis3, angle: Float)
    case round(target: BodyTarget, radius: Float)
    case addHole(target: BodyTarget, diameter: Float)
    case duplicate(target: BodyTarget)
    case delete(target: BodyTarget)
    case undo
    case redo

    /// A short line for the caption: what is actually being done.
    var summary: String {
        func mm(_ v: Float) -> String {
            let value = (v * 10_000).rounded() / 10
            return value == value.rounded() ? "\(Int(value)) mm" : String(format: "%.1f mm", value)
        }
        switch self {
        case .createCube(let size, _, _): return "Create cube · \(mm(size))"
        case .createBox(let w, let d, let h, _, _): return "Create box · \(mm(w)) × \(mm(d)) × \(mm(h))"
        case .createCylinder(let r, let h, _, _): return "Create cylinder · r \(mm(r)) × \(mm(h))"
        case .createPrism(_, let depth, _, _): return "Create profile · \(mm(depth)) deep"
        case .startSketch: return "Start sketch"
        case .addRectangle(let w, let h): return "Rectangle · \(mm(w)) × \(mm(h))"
        case .addCircle(let r): return "Circle · r \(mm(r))"
        case .addLine(let dx, let dy): return "Line · \(mm(simd_length(SIMD2(dx, dy))))"
        case .finishSketch: return "Finish sketch"
        case .extrude(let d, let cut): return "\(cut ? "Cut" : "Extrude") · \(mm(d))"
        case .resize(_, let changes):
            return "Resize · " + changes.map { "\($0.mode == .add && $0.value >= 0 ? "+" : "")\(mm($0.value)) \($0.axis.rawValue)" }.joined(separator: ", ")
        case .move(_, .camera(let direction, let d)): return "Move \(direction.rawValue) · \(mm(d))"
        case .move(_, .world(let v)): return "Move · \(mm(v.x)), \(mm(v.y)), \(mm(v.z))"
        case .rotate(_, let axis, let angle): return "Rotate · \(Int((angle * 180 / .pi).rounded()))° about \(axis.rawValue)"
        case .round(_, let r): return "Round · \(mm(r))"
        case .addHole(_, let d): return "Hole · Ø \(mm(d))"
        case .duplicate: return "Duplicate"
        case .delete: return "Delete"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }
}

/// The small amount of state a model may see when choosing tools.
enum SelectionKind: Equatable {
    case none, box, cylinder, other
}

struct ToolContext: Equatable {
    var isSketching = false
    var selection: SelectionKind = .none
    var defaultUnit = "cm"
    var canUndo = true
    var canRedo = true
}

enum ToolError: Error, Equatable {
    case unknownTool(String)
    case missing(String)
    case invalid(String)
    case notAvailable(String)

    /// Text for the caption.
    var message: String {
        switch self {
        case .unknownTool(let name): "I don't know how to \(name)"
        case .missing(let name): "Missing \(name)"
        case .invalid(let detail): detail
        case .notAvailable(let detail): detail
        }
    }
}
