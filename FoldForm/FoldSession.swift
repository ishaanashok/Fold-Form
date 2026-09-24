import Foundation

/// The history of folds applied to the block, and the "hold" rule.
///
/// - The live fold follows the hinge, applied on top of the last committed shape.
/// - `hold` bakes the currently shown fold into the shape. From then on the model stays exactly as
///   it is, ignoring further hinge movement, until the hinge comes back to flat.
/// - Once flat, the hold releases and the next fold starts from the held shape — so folds stack:
///   fold, hold, open flat, fold somewhere else, hold, and so on.
struct FoldSession {
    /// Within this much of flat (1°) the hinge counts as "back to flat" and releases a hold.
    static let flatThresholdRadians = 1.0 * .pi / 180

    /// The unfolded block as the document evaluates it.
    private(set) var source: RenderMesh
    /// Each held fold's resulting shape, oldest first.
    private(set) var committed: [RenderMesh] = []
    private(set) var isHolding = false
    /// Bumps whenever the displayed shape changes for a reason other than the live hinge/camera.
    private(set) var revision = 0

    init(source: RenderMesh) {
        self.source = source
    }

    /// The shape the next live fold is applied to.
    var base: RenderMesh { committed.last ?? source }
    var foldCount: Int { committed.count }

    func canHold(bend: Double) -> Bool {
        !isHolding && bend > Self.flatThresholdRadians
    }

    /// The mesh to show: the held shape while holding, otherwise the live fold on top of the base.
    func displayedMesh(bend: Double, frame: FoldFrame) -> RenderMesh {
        isHolding ? base : BendDeformer.deform(base, bendAngleRadians: bend, frame: frame)
    }

    /// Bakes the fold currently shown into the shape and holds it. Returns false if there is
    /// nothing to hold (already holding, or the hinge is flat).
    @discardableResult
    mutating func hold(bend: Double, frame: FoldFrame) -> Bool {
        guard canHold(bend: bend) else { return false }
        committed.append(BendDeformer.deform(base, bendAngleRadians: bend, frame: frame))
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

    /// Discards every held fold, back to the original block.
    mutating func clearFolds() {
        guard !committed.isEmpty || isHolding else { return }
        committed = []
        isHolding = false
        revision += 1
    }

    /// The document produced a different block: start over from it.
    mutating func reset(source: RenderMesh) {
        self.source = source
        committed = []
        isHolding = false
        revision += 1
    }
}
