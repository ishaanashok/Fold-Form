import Foundation
import simd

enum ActionResult: Equatable {
    case done(String)
    case failed(String)
}

struct SequenceResult: Equatable {
    var results: [ActionResult] = []
    /// How many actions took effect and were kept.
    var completed = 0
    /// Why it stopped, if it did.
    var failure: String?
}

/// Applies `CADAction`s to the design: the one place voice commands and Imagine plans change
/// anything. It edits the `AppModel`, so the fold, the hinge, autosave and export follow without
/// knowing where the change came from. Each call is a single undo step.
@MainActor
final class CADActionExecutor {
    private let appModel: AppModel
    private let viewport: ViewportEntities

    /// Bodies as they were when the request began, plate first (`P0`, `P1`, …).
    private var requestBodies: [UUID] = []
    /// Where the design was centred when the request began; `.fromCentre` placements are relative to it.
    private var designCentre: SIMD3<Float> = .zero
    /// Bodies made by earlier steps of this request that were given a name.
    private var names: [String: UUID] = [:]

    private static let gap: Float = 0.01

    init(appModel: AppModel, viewport: ViewportEntities) {
        self.appModel = appModel
        self.viewport = viewport
    }

    private struct Failure: Error { let message: String }
    private func fail(_ message: String) -> Failure { Failure(message: message) }

    // MARK: Running

    /// Runs the actions in order and stops at the first that can't be done, keeping what came
    /// before it. All of it is one undo step.
    @discardableResult
    func run(_ actions: [CADAction]) -> SequenceResult { execute(actions, atomic: false) }

    /// All or nothing: if any action fails, the design is put back exactly as it was.
    @discardableResult
    func runAtomically(_ actions: [CADAction]) -> SequenceResult { execute(actions, atomic: true) }

    private func execute(_ actions: [CADAction], atomic: Bool) -> SequenceResult {
        guard !actions.isEmpty else { return SequenceResult() }
        if actions == [.undo] || actions == [.redo] { return stepThroughHistory(actions[0]) }

        viewport.update(appModel: appModel)
        beginRequest()
        var result = SequenceResult()
        var changedDesign = false
        viewport.transact { () -> ViewportEntities.TransactionOutcome in
            for action in actions {
                do {
                    guard action != .undo, action != .redo else { throw fail("Undo can't be combined with other steps") }
                    let message = try perform(action)
                    if !Self.isSketchOnly(action) { changedDesign = true }
                    result.results.append(.done(message))
                    result.completed += 1
                } catch let failure as Failure {
                    result.results.append(.failed(failure.message))
                    result.failure = failure.message
                    break
                } catch {
                    result.results.append(.failed(error.localizedDescription))
                    result.failure = error.localizedDescription
                    break
                }
            }
            if atomic ? result.failure != nil : result.completed == 0 { return .rollback }
            // Drawing shapes has its own undo, so a request that only draws leaves no history entry.
            return changedDesign ? .commit : .keep
        }
        if atomic, result.failure != nil {
            // Everything was rolled back, so nothing counts as done.
            result.results = [.failed(result.failure ?? "")]
            result.completed = 0
        }
        return result
    }

    private static func isSketchOnly(_ action: CADAction) -> Bool {
        switch action {
        case .startSketch, .addRectangle, .addCircle, .addLine, .finishSketch: true
        default: false
        }
    }

    private func stepThroughHistory(_ action: CADAction) -> SequenceResult {
        viewport.update(appModel: appModel)
        switch action {
        case .undo:
            guard viewport.hasUndo else { return SequenceResult(results: [.failed("Nothing to undo")], completed: 0, failure: "Nothing to undo") }
            viewport.undo()
            return SequenceResult(results: [.done("Undo")], completed: 1, failure: nil)
        default:
            guard viewport.canRedo else { return SequenceResult(results: [.failed("Nothing to redo")], completed: 0, failure: "Nothing to redo") }
            viewport.redo()
            return SequenceResult(results: [.done("Redo")], completed: 1, failure: nil)
        }
    }

    private func beginRequest() {
        requestBodies = appModel.document.partStudio.orderedBodyIDs
        names = [:]
        if let box = sceneBounds() { designCentre = (box.min + box.max) / 2 } else { designCentre = .zero }
    }

    // MARK: One action

    private func perform(_ action: CADAction) throws -> String {
        switch action {
        case .createCube(let size, let placement, let name):
            try check(size)
            return try add(GeometryBuilder.box(width: Double(size), height: Double(size), depth: Double(size)), placement, name, action)
        case .createBox(let width, let depth, let height, let placement, let name):
            try check(width, depth, height)
            return try add(GeometryBuilder.box(width: Double(width), height: Double(height), depth: Double(depth)), placement, name, action)
        case .createCylinder(let radius, let height, let placement, let name):
            try check(radius, height)
            // Built along z, then stood up so its axis is y: x × -z = y keeps the winding.
            let mesh = GeometryBuilder.cylinder(radius: Double(radius), height: Double(height))
                .placed(origin: .zero, u: [1, 0, 0], v: [0, 0, -1], n: [0, 1, 0])
            return try add(mesh, placement, name, action)
        case .createPrism(let outline, let depth, let placement, let name):
            try check(depth)
            guard outline.count >= 3, outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw fail("That outline isn't a shape") }
            let lo = outline.reduce(outline[0], simd_min), hi = outline.reduce(outline[0], simd_max)
            let middle = (lo + hi) / 2
            let centred = outline.map { SIMD2<Double>(Double($0.x - middle.x), Double($0.y - middle.y)) }
            return try add(GeometryBuilder.prism(outline: centred, height: Double(depth), centered: true), placement, name, action)
        case .startSketch:
            guard !viewport.sketch.isActive else { throw fail("Already sketching") }
            viewport.beginSketch()
            return action.summary
        case .addRectangle(let width, let height):
            try requireSketch()
            try checkShape(width, height)
            viewport.sketch.replaceShapes(viewport.sketch.shapes + [.rectangle([-width / 2, -height / 2], [width / 2, height / 2])])
            return action.summary
        case .addCircle(let radius):
            try requireSketch()
            try checkShape(radius)
            viewport.sketch.replaceShapes(viewport.sketch.shapes + [.circle(center: .zero, radius: radius)])
            return action.summary
        case .addLine(let dx, let dy):
            try requireSketch()
            try checkShape(simd_length(SIMD2(dx, dy)))
            var start = SIMD2<Float>.zero
            if case .line(_, let end)? = viewport.sketch.shapes.last { start = end }
            viewport.sketch.replaceShapes(viewport.sketch.shapes + [.line(start, start + SIMD2(dx, dy))])
            return action.summary
        case .finishSketch:
            try requireSketch()
            viewport.endSketch()
            return action.summary
        case .extrude(let distance, let cut):
            return try extrude(distance, cut: cut, action)
        case .resize(let target, let changes):
            return try resize(target, changes, action)
        case .move(let target, let displacement):
            return try move(target, displacement, action)
        case .rotate(let target, let axis, let angle):
            return try rotate(target, axis, angle, action)
        case .round(let target, let radius):
            return try round(target, radius, action)
        case .addHole(let target, let diameter):
            return try hole(target, diameter, action)
        case .duplicate(let target):
            return try duplicate(target, action)
        case .delete(let target):
            return try delete(target, action)
        case .undo, .redo:
            throw fail("Undo can't be combined with other steps")
        }
    }

    // MARK: Helpers

    private func check(_ values: Float...) throws {
        for v in values where !(v.isFinite && ToolCatalog.lengthRange.contains(v)) { throw fail("That size is out of range") }
    }

    private func part(for target: BodyTarget) throws -> DesignPart {
        let id: UUID
        switch target {
        case .selected:
            guard let selected = viewport.selectedDocumentBodyID else { throw fail("Select a part first") }
            id = selected
        case .existing(let index):
            guard requestBodies.indices.contains(index) else { throw fail("There is no part P\(index)") }
            id = requestBodies[index]
        case .named(let name):
            guard let known = names[name] else { throw fail("There is no part called \(name)") }
            id = known
        }
        guard let solid = appModel.document.partStudio.body(id), let part = DesignScene.part(from: (id, solid.mesh)) else {
            throw fail("That part is gone")
        }
        return part
    }

    private func sceneBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        let boxes = appModel.document.partStudio.orderedBodyIDs.compactMap { id -> (min: SIMD3<Float>, max: SIMD3<Float>)? in
            guard let mesh = appModel.document.partStudio.body(id)?.mesh, !mesh.positions.isEmpty else { return nil }
            return mesh.boundingBox
        }
        guard let first = boxes.first else { return nil }
        return (boxes.map(\.min).reduce(first.min, simd_min), boxes.map(\.max).reduce(first.max, simd_max))
    }

    /// The world axis (with sign) that `direction` on screen is closest to.
    private func nearestWorldAxis(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let index = (0..<3).max { abs(direction[$0]) < abs(direction[$1]) } ?? 0
        var axis = SIMD3<Float>.zero
        axis[index] = direction[index] < 0 ? -1 : 1
        return axis
    }

    private func axisIndex(_ axis: Axis3, size: SIMD3<Float>) -> Int {
        switch axis {
        case .x: 0
        case .y: 1
        case .z: 2
        case .thinnest: (0..<3).min { size[$0] < size[$1] } ?? 1
        case .longest: (0..<3).max { size[$0] < size[$1] } ?? 0
        }
    }

    /// Puts a new body where asked, adds it to the design and selects it.
    private func add(_ mesh: RenderMesh, _ placement: Placement, _ name: String?, _ action: CADAction) throws -> String {
        let box = mesh.boundingBox
        let offset: SIMD3<Float>
        switch placement {
        case .beside:
            if let scene = sceneBounds() {
                let z = (scene.min.z + scene.max.z) / 2 - (box.min.z + box.max.z) / 2
                offset = SIMD3(scene.max.x + Self.gap - box.min.x, scene.min.y - box.min.y, z)
            } else {
                offset = SIMD3(0, -box.min.y, 0)
            }
        case .fromCentre(let v):
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite, simd_length(v) < 10 else { throw fail("That position is out of range") }
            offset = designCentre + v - mesh.center
        }
        guard let id = appModel.addViewportSolids([mesh.translated(by: offset)]).last else { throw fail("Couldn't add that part") }
        if let name { names[name] = id }
        viewport.select(documentBodyID: id)
        return action.summary
    }

    /// Replaces a body's shape, keeps it selected.
    private func commit(_ id: UUID, _ mesh: RenderMesh, _ action: CADAction) -> String {
        appModel.applyBodyEdit([id: mesh], label: action.summary)
        viewport.select(documentBodyID: id)
        return action.summary
    }

    // MARK: Sketching

    private func requireSketch() throws {
        guard viewport.sketch.isActive else { throw fail("Start a sketch first") }
    }

    private func checkShape(_ values: Float...) throws {
        for v in values where !(v.isFinite && v > SketchGeometry.minimumSize && v < 2) { throw fail("That shape is too small or too big") }
    }

    private func extrude(_ distance: Float, cut: Bool, _ action: CADAction) throws -> String {
        try requireSketch()
        guard distance.isFinite, ToolCatalog.extrudeRange.contains(distance) else { throw fail("That distance is out of range") }
        let sketch = viewport.sketch
        guard !sketch.shapes.isEmpty else { throw fail("Draw a shape first") }
        guard sketch.canExtrude else { throw fail("Close the shape first") }
        let before = Set(ids)
        sketch.startExtrude(cut: cut)
        sketch.setDepth(distance)
        viewport.confirmExtrude(recordUndo: false)
        if !cut, let added = ids.last(where: { !before.contains($0) }) { viewport.select(documentBodyID: added) }
        return action.summary
    }

    private var ids: [UUID] { appModel.document.partStudio.orderedBodyIDs }

    // MARK: Edits

    private func resize(_ target: BodyTarget, _ changes: [DimensionChange], _ action: CADAction) throws -> String {
        let part = try part(for: target)
        guard part.kind != .other else { throw fail("This part can't be resized after rotating") }
        var lo = part.min, hi = part.max
        func set(_ i: Int, to size: Float) {
            if i == 1 {
                hi.y = lo.y + size          // height grows up from the base
            } else {
                let middle = (lo[i] + hi[i]) / 2
                lo[i] = middle - size / 2
                hi[i] = middle + size / 2
            }
        }
        for change in changes {
            let i = axisIndex(change.axis, size: hi - lo)
            let size = change.mode == .set ? change.value : (hi[i] - lo[i]) + change.value
            try check(size)
            set(i, to: size)
            if part.kind == .cylinder, i != part.axis {
                // A cylinder is round: changing its width changes its diameter.
                for j in 0..<3 where j != i && j != part.axis { set(j, to: size) }
            }
        }
        guard let mesh = part.rebuilt(lo: lo, hi: hi) else { throw fail("Couldn't resize that part") }
        return commit(part.id, mesh, action)
    }

    private func move(_ target: BodyTarget, _ displacement: Displacement, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        let offset: SIMD3<Float>
        switch displacement {
        case .camera(let direction, let distance):
            let axes = viewport.viewAxes
            let onScreen: SIMD3<Float>
            switch direction {
            case .right: onScreen = axes.right
            case .left: onScreen = -axes.right
            case .up: onScreen = axes.up
            case .down: onScreen = -axes.up
            case .forward: onScreen = axes.forward
            case .back: onScreen = -axes.forward
            }
            offset = nearestWorldAxis(onScreen) * distance
        case .world(let v):
            offset = v
        }
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite, simd_length(offset) < 5 else { throw fail("That move is out of range") }
        return commit(part.id, part.mesh.translated(by: offset), action)
    }

    private func rotate(_ target: BodyTarget, _ axis: Axis3, _ angle: Float, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        guard angle.isFinite else { throw fail("Bad angle") }
        var direction = SIMD3<Float>.zero
        direction[axisIndex(axis, size: part.size)] = 1
        let rotation = simd_quatf(angle: angle, axis: direction)
        return commit(part.id, part.mesh.rotated(by: rotation, about: part.center), action)
    }

    private func round(_ target: BodyTarget, _ radius: Float, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        try check(radius)
        guard part.kind == .box else { throw fail("Only box-shaped parts can be rounded") }
        guard let mesh = part.roundedMesh(radius: radius) else { throw fail("That rounding is too big for this part") }
        return commit(part.id, mesh, action)
    }

    private func hole(_ target: BodyTarget, _ diameter: Float, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        try check(diameter)
        let size = part.size
        let order = (0..<3).sorted { size[$0] < size[$1] }
        // Through the thin side of a slab; through the face toward the viewer on a chunky part.
        let axis: Int
        if size[order[0]] < 0.7 * size[order[1]] {
            axis = order[0]
        } else {
            let facing = nearestWorldAxis(viewport.viewAxes.forward)
            axis = (0..<3).first { facing[$0] != 0 } ?? 2
        }
        let across = (0..<3).filter { $0 != axis }.map { size[$0] }.min() ?? 0
        guard diameter < across - 0.0002 else { throw fail("The hole is wider than the part") }
        let basis: (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>)
        switch axis {
        case 0: basis = ([0, 1, 0], [0, 0, 1], [1, 0, 0])
        case 1: basis = ([1, 0, 0], [0, 0, -1], [0, 1, 0])
        default: basis = ([1, 0, 0], [0, 1, 0], [0, 0, 1])
        }
        let cutter = GeometryBuilder.cylinder(radius: Double(diameter / 2), height: Double(size[axis] + 0.002))
            .placed(origin: part.center, u: basis.u, v: basis.v, n: basis.n)
        let result = MeshCSG.subtract(part.mesh, cutter)
        guard !result.positions.isEmpty, let after = result.solidProperties?.volume, after < part.volume - 1e-9 else {
            throw fail("Couldn't cut a hole there")
        }
        return commit(part.id, result, action)
    }

    private func duplicate(_ target: BodyTarget, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        let right = nearestWorldAxis(viewport.viewAxes.right)
        let width = abs(simd_dot(right, part.size))
        let copy = part.mesh.translated(by: right * (width + 0.006))
        guard let id = appModel.addViewportSolids([copy]).last else { throw fail("Couldn't copy that part") }
        if let style = appModel.partStyles[part.id] { appModel.setStyles([id: style]) }
        viewport.select(documentBodyID: id)
        return action.summary
    }

    private func delete(_ target: BodyTarget, _ action: CADAction) throws -> String {
        let part = try part(for: target)
        guard part.id != appModel.document.partStudio.orderedBodyIDs.first else { throw fail("The base plate can't be deleted") }
        guard appModel.removeViewportSolid(bodyID: part.id) else { throw fail("Couldn't delete that part") }
        viewport.select(documentBodyID: nil)
        return action.summary
    }
}
