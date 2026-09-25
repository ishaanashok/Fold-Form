import Foundation

/// Everything that is on the workbench and the history of folds applied to it, plus the "hold" rule.
///
/// - The workbench is one or more parts. The first is the document's plate; sketches add more.
/// - The live fold follows the hinge, applied on top of the last committed shapes, to every part.
/// - `hold` bakes the currently shown fold into the shapes. From then on they stay exactly as they
///   are, ignoring further hinge movement, until the hinge comes back to flat.
/// - Once flat, the hold releases and the next fold starts from the held shapes, so folds stack.
struct FoldSession {
    /// Within this much of flat (1°) the hinge counts as "back to flat" and releases a hold.
    static let flatThresholdRadians = 1.0 * .pi / 180
    /// Identity of the document's own plate.
    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    typealias Shapes = [UUID: RenderMesh]

    /// The document's plate as it evaluates, unfolded.
    private(set) var source: RenderMesh
    /// Parts in creation order.
    private(set) var order: [UUID]
    private var sources: Shapes
    /// Each held fold's resulting shapes, oldest first.
    private(set) var committed: [Shapes] = []
    private(set) var isHolding = false
    /// Bumps whenever the displayed shapes change for a reason other than the live hinge/camera.
    private(set) var revision = 0

    init(source: RenderMesh) {
        self.source = source
        self.order = [Self.primaryID]
        self.sources = [Self.primaryID: source]
    }

    /// The shapes the next live fold is applied to.
    var base: Shapes { committed.last ?? sources }
    var foldCount: Int { committed.count }
    var partCount: Int { order.count }
    /// The plate's own shape, for callers that only care about that one part.
    var primary: RenderMesh { base[Self.primaryID] ?? .empty }

    func canHold(bend: Double) -> Bool {
        !isHolding && bend > Self.flatThresholdRadians
    }

    /// The meshes to show, in order: the held shapes while holding, otherwise the live fold on top.
    func displayedParts(bend: Double, frame: FoldFrame, corner: CornerStyle = .fillet) -> [(id: UUID, mesh: RenderMesh)] {
        let shapes = base
        return order.compactMap { id in
            guard let mesh = shapes[id] else { return nil }
            return (id, isHolding ? mesh : BendDeformer.deform(mesh, bendAngleRadians: bend, frame: frame, corner: corner))
        }
    }

    func displayedMesh(bend: Double, frame: FoldFrame, corner: CornerStyle = .fillet) -> RenderMesh {
        displayedParts(bend: bend, frame: frame, corner: corner).first { $0.id == Self.primaryID }?.mesh ?? .empty
    }

    /// Bakes the fold currently shown into the shapes and holds it. Returns false if there is
    /// nothing to hold (already holding, or the hinge is flat).
    @discardableResult
    mutating func hold(bend: Double, frame: FoldFrame, corner: CornerStyle = .fillet) -> Bool {
        guard canHold(bend: bend) else { return false }
        var folded = Shapes()
        for (id, mesh) in base { folded[id] = BendDeformer.deform(mesh, bendAngleRadians: bend, frame: frame, corner: corner) }
        committed.append(folded)
        isHolding = true
        revision += 1
        return true
    }

    /// Call whenever the hinge moves. Returns true if a hold was released because it is flat again.
    @discardableResult
    mutating func bendChanged(_ bend: Double) -> Bool {
        guard isHolding, bend <= Self.flatThresholdRadians else { return false }
        isHolding = false
        revision += 1
        return true
    }

    /// Removes the most recent held fold and goes back to following the hinge live.
    mutating func undo() {
        guard !committed.isEmpty else { return }
        committed.removeLast()
        isHolding = false
        revision += 1
    }

    /// Discards every held fold, back to the unfolded parts.
    mutating func clearFolds() {
        guard !committed.isEmpty || isHolding else { return }
        committed = []
        isHolding = false
        revision += 1
    }

    // MARK: Parts

    /// Adds a part. It shows unfolded in every earlier stage, so undoing a fold never removes it.
    mutating func addPart(id: UUID, mesh: RenderMesh) {
        order.append(id)
        sources[id] = mesh
        for index in committed.indices { committed[index][id] = mesh }
        revision += 1
    }

    /// Copies a part, with the same fold history, moved by `offset`.
    @discardableResult
    mutating func duplicatePart(_ id: UUID, as newID: UUID, offset: SIMD3<Float>) -> Bool {
        guard let original = sources[id] else { return false }
        order.append(newID)
        sources[newID] = original.translated(by: offset)
        for index in committed.indices {
            if let shape = committed[index][id] { committed[index][newID] = shape.translated(by: offset) }
        }
        revision += 1
        return true
    }

    /// The plate cannot be deleted; anything else can.
    mutating func removePart(_ id: UUID) {
        guard id != Self.primaryID, sources[id] != nil else { return }
        order.removeAll { $0 == id }
        sources[id] = nil
        for index in committed.indices { committed[index][id] = nil }
        revision += 1
    }

    /// The document produced a different plate: start over from it, dropping every other part.
    mutating func reset(source: RenderMesh) {
        self.source = source
        order = [Self.primaryID]
        sources = [Self.primaryID: source]
        committed = []
        isHolding = false
        revision += 1
    }
}
