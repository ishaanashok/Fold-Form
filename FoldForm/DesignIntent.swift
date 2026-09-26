import Foundation
import simd

/// What a design should look like: which parts are meant to be the same, how they are laid out and
/// how they should be finished. It is not tied to any kind of object. The on-device model proposes a
/// plan from a description of the parts; geometry checks it and carries it out.
struct DesignPlan: Equatable {
    struct Group: Equatable {
        /// What the parts are called ("leg", "shelf", "wheel"...). Only used in messages.
        var role: String
        /// Part indices (P0, P1, ...) as listed in the scene description.
        var members: [Int]
        var identicalSize: Bool
        /// Placed symmetrically about the middle of the whole design.
        var mirrored: Bool
        /// Edges within reach of a neighbouring part's edge sit exactly flush with it.
        var alignEdges: Bool
        /// A row of three or more is spaced evenly.
        var evenlySpaced: Bool
        /// Thin flat parts get rounded corners.
        var softenCorners: Bool
        /// A palette colour name, or empty for the default.
        var material: String
    }

    /// Anything the model calls the design: "table", "bookcase", "robot". Free text, used in messages.
    var kind: String
    var groups: [Group]
    var reason: String
    /// Add rails between four posts standing on a slab. nil lets the geometry decide.
    var addRails: Bool? = nil
}

enum DesignIntent {
    /// What the model is told about how designs look. It describes principles, not a list of objects, so
    /// anything with parts that repeat, mirror or line up is covered.
    static let knowledge = """
        Principles of how well-made designs look, whatever they are (furniture, machines, buildings, \
        brackets, toys, enclosures, robots):
        - Parts that do the same job are identical: the same size in every direction. Four legs, two \
        uprights, three shelves, six wheels, a row of identical fins.
        - A design is usually symmetric about its middle. A part on the centre line sits exactly on it, and \
        a part off it has an identical partner on the other side, the same distance out.
        - Neighbouring parts line up: an edge that almost meets a neighbour's edge sits exactly flush with \
        it, and a part that almost touches another touches it.
        - Repeated parts in a row are evenly spaced.
        - Thin flat parts (tops, seats, panels, plates) look better with rounded corners.
        - A part that is clearly a different kind (much larger, much taller, a different shape) is its own \
        group and is not made identical to the others.
        - Choose colours that suit the thing: natural wood tones for wooden things (a lighter main surface, \
        darker supports), steel or grey for machines and brackets, bright colours for toys.
        Examples: a table is a top with identical legs at the corners; a chair is a seat, identical legs \
        and a tall back centred on one edge; a bookcase is identical uprights with identical, evenly \
        spaced shelves between them; a bracket is a plate with identical holes; a robot is a torso, \
        mirrored arms and legs, and a head on the centre line.
        """

    /// Turns the model's answer into a plan geometry can safely run, or nil if nothing usable remains.
    /// Every index must exist and belong to one group only, the parts in an identical group must be
    /// plausibly the same kind of part (within 3x of each other in every dimension), and a colour must
    /// be in the palette, whatever the model claims.
    static func validated(_ plan: DesignPlan, partSizes: [SIMD3<Float>]) -> DesignPlan? {
        var used = Set<Int>()
        var groups: [DesignPlan.Group] = []
        for group in plan.groups {
            var members: [Int] = []
            for index in group.members where partSizes.indices.contains(index) && !used.contains(index) {
                members.append(index)
                used.insert(index)
            }
            guard !members.isEmpty else { continue }
            var group = group
            group.members = members
            if group.identicalSize, members.count >= 2 {
                let sorted = members.map { [partSizes[$0].x, partSizes[$0].y, partSizes[$0].z].sorted() }
                let plausible = (0..<3).allSatisfy { d in
                    guard let low = sorted.map({ $0[d] }).min(), let high = sorted.map({ $0[d] }).max() else { return false }
                    return low > 1e-9 && high / low <= 3
                }
                guard plausible else { continue }
            }
            group.material = Palette.style(group.material)?.name ?? ""
            groups.append(group)
        }
        guard !groups.isEmpty else { return nil }
        let kind = plan.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return DesignPlan(kind: String(kind.prefix(40)), groups: groups, reason: plan.reason, addRails: plan.addRails)
    }

    /// True for the words that mean the design has not been given a specific name.
    static func isGeneric(_ kind: String) -> Bool {
        ["", "other", "assembly", "unknown", "design", "object"].contains(kind.lowercased())
    }
}
