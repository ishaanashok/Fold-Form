import Foundation
import simd
import FoundationModels

/// The local model's pick between the readings geometry offered.
struct AdvisorDecision: Equatable {
    /// Index into the options, or -1 to leave the drawing as it is.
    var choice: Int
    var reason: String
}

protocol TouchUpAdvisor: Sendable {
    func decide(summary: String, options: [String]) async -> AdvisorDecision?
    /// A design plan for the parts described, or nil when there is no model or it had no answer.
    func plan(description: String) async -> DesignPlan?
}

extension TouchUpAdvisor {
    func plan(description: String) async -> DesignPlan? { nil }
}

@Generable
struct TouchUpChoice {
    @Guide(description: "Index of the option that best matches what the user was trying to make, or -1 if none fits")
    var choice: Int
    @Guide(description: "One short sentence saying why")
    var reason: String
}

@Generable
struct GroupPlan {
    @Guide(description: "What these parts are, for example leg, shelf, upright, wheel, arm, panel")
    var role: String
    @Guide(description: "The numbers of the parts in this group (0 for P0, 1 for P1, ...). Each part in at most one group.")
    var members: [Int]
    @Guide(description: "True if these parts do the same job and should be exactly the same size")
    var identicalSize: Bool
    @Guide(description: "True if these parts should sit symmetrically about the middle of the design (on the centre line, or in mirrored pairs)")
    var mirrored: Bool
    @Guide(description: "True if an edge that nearly meets a neighbouring part's edge should sit exactly flush with it")
    var alignEdges: Bool
    @Guide(description: "True if three or more of these parts stand in a row and should be spaced evenly")
    var evenlySpaced: Bool
    @Guide(description: "True if these are thin flat parts (tops, seats, panels, plates) that should get rounded corners")
    var softenCorners: Bool
    @Guide(description: "Colour for these parts", .anyOf(["oak", "walnut", "pine", "cherry", "white", "black", "grey", "steel", "blue", "red", "green"]))
    var material: String
}

@Generable
struct DesignPlanOutput {
    @Guide(description: "What is being built, in one or two words, for example table, bookcase, robot, bracket, shed")
    var kind: String
    @Guide(description: "Groups of parts that belong together. Put every part in a group; leave a part out only if it does not belong with anything.")
    var groups: [GroupPlan]
    @Guide(description: "True to add rails joining four posts that stand on a slab, as under a table top or chair seat")
    var addRails: Bool
    @Guide(description: "One short sentence explaining the design")
    var reason: String
}

/// Asks Apple's on-device language model to choose. It never invents geometry: it can only pick one
/// of the candidates the triangle maths produced, or say none fits. Returns nil when the model is
/// unavailable (for example in the simulator) or too slow, and the caller uses the geometry's own pick.
struct OnDeviceAdvisor: TouchUpAdvisor {
    static let timeoutSeconds = 8.0

    func decide(summary: String, options: [String]) async -> AdvisorDecision? {
        guard case .available = SystemLanguageModel.default.availability, !options.isEmpty else { return nil }
        let prompt = """
        \(summary)

        Options:
        \(options.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
        """
        return await withTaskGroup(of: AdvisorDecision?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: """
                    You help a CAD app tidy up a hand-drawn shape. You are given measurements of the shape \
                    and numbered options for what it was meant to be. Pick the number of the option a person \
                    most likely intended, judging from the side lengths and angles. Answer -1 if the drawing \
                    looks deliberately irregular or no option fits.
                    """)
                guard let response = try? await session.respond(to: prompt, generating: TouchUpChoice.self) else { return nil }
                let content = response.content
                guard content.choice >= -1, content.choice < options.count else { return nil }
                return AdvisorDecision(choice: content.choice, reason: content.reason)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reads a description of the parts and says what is being built and which parts belong together.
    /// Guided generation keeps the answer in the plan's shape; geometry still validates every index.
    func plan(description: String) async -> DesignPlan? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return await withTaskGroup(of: DesignPlan?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: """
                    You are the design-intent engine of a CAD app. A user sketched several parts of something and \
                    the app describes them below with measurements. Work out what the user is building, whatever it \
                    is, which parts are meant to be the same, how they should be laid out and what colours suit \
                    it, so the app can finish the design. Answer only from the measurements.

                    \(DesignIntent.knowledge)
                    """)
                var options = GenerationOptions()
                options.temperature = 0
                guard let response = try? await session.respond(to: description, generating: DesignPlanOutput.self, options: options) else { return nil }
                let output = response.content
                return DesignPlan(
                    kind: output.kind,
                    groups: output.groups.map {
                        DesignPlan.Group(role: $0.role, members: $0.members, identicalSize: $0.identicalSize, mirrored: $0.mirrored,
                                         alignEdges: $0.alignEdges, evenlySpaced: $0.evenlySpaced, softenCorners: $0.softenCorners, material: $0.material)
                    },
                    reason: output.reason,
                    addRails: output.addRails
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 2 * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// What a touch up did, in words for the person using the app.
struct TouchUpOutcome {
    var message: String
    var changed: Bool
}

/// Runs a touch up: geometry finds bumps and candidate readings, the advisor picks between them,
/// geometry applies the result. Nothing here mutates the model; the caller applies what comes back.
struct TouchUpEngine {
    static let unknownMessage = "Wasn't able to figure out what was being created."
    var advisor: TouchUpAdvisor = OnDeviceAdvisor()

    // MARK: Sketch outlines

    struct SketchResult {
        var shapes: [SketchShape]?
        var outcome: TouchUpOutcome
    }

    func touchUp(shapes: [SketchShape], segments: [(SIMD2<Float>, SIMD2<Float>)], tolerance: Float) async -> SketchResult {
        guard !shapes.isEmpty else {
            return SketchResult(shapes: nil, outcome: TouchUpOutcome(message: "Draw something first, then touch it up.", changed: false))
        }
        let loops = SketchGeometry.loops(of: segments, tolerance: tolerance)
        guard !loops.isEmpty else {
            // Rectangles and circles come out exact; only loose lines leave nothing to read.
            let onlyExact = segments.isEmpty
            return SketchResult(shapes: nil, outcome: TouchUpOutcome(
                message: onlyExact ? "Nothing to touch up. Rectangles and circles are already exact." : Self.unknownMessage,
                changed: false
            ))
        }

        var rebuilt: [SketchShape] = shapes.filter { shape in
            guard case .line(let a, let b) = shape else { return true }
            return !loops.contains { loop in
                loop.contains { simd_distance($0, a) <= tolerance } && loop.contains { simd_distance($0, b) <= tolerance }
            }
        }
        var bumps = 0
        var readings: [String] = []
        var changedAny = false
        var understoodAny = false

        for raw in loops {
            let resolution = await resolve(raw)
            bumps += resolution.analysis.bumpsRemoved
            if let chosen = resolution.chosen {
                understoodAny = true
                readings.append(chosen.kind.rawValue)
                if let circle = chosen.circle {
                    rebuilt.append(.circle(center: circle.center, radius: circle.radius))
                } else {
                    rebuilt += Self.lines(chosen.points)
                }
            } else {
                rebuilt += Self.lines(resolution.analysis.cleaned)
            }
            if resolution.changed { changedAny = true }
        }

        guard changedAny else {
            let message = understoodAny
                ? "Already clean: this looks like a \(readings.joined(separator: " and a "))."
                : Self.unknownMessage
            return SketchResult(shapes: nil, outcome: TouchUpOutcome(message: message, changed: false))
        }
        var parts: [String] = []
        if bumps > 0 { parts.append("removed \(bumps) bump\(bumps == 1 ? "" : "s")") }
        if !readings.isEmpty { parts.append("snapped to a \(readings.joined(separator: " and a "))") }
        else { parts.append("couldn't tell what shape it was, so only cleaned the outline") }
        let text = parts.joined(separator: " and ")
        return SketchResult(shapes: rebuilt, outcome: TouchUpOutcome(message: text.prefix(1).uppercased() + text.dropFirst() + ".", changed: true))
    }

    /// How one outline is read and what it becomes.
    struct Resolution {
        var analysis: LoopAnalysis
        var chosen: ShapeCandidate?
        /// True when the outline differs from what was drawn: bumps removed or corners snapped.
        var changed: Bool
        /// The outline to use: the chosen reading, else the bump-free corners.
        var points: [SIMD2<Float>] { chosen?.points ?? analysis.cleaned }
    }

    /// Geometry proposes readings, the advisor (when there is one) chooses, and a veto or no fit
    /// leaves the bump-free outline.
    func resolve(_ raw: [SIMD2<Float>], quadTolerance: Float = 14) async -> Resolution {
        let analysis = ShapeAnalysis.analyze(raw, quadTolerance: quadTolerance)
        var chosen = analysis.bestCandidate
        if !analysis.candidates.isEmpty {
            let options = analysis.candidates.map { "\($0.kind.rawValue): \($0.note)" }
            if let decision = await advisor.decide(summary: analysis.summary, options: options) {
                chosen = decision.choice >= 0 ? analysis.candidates[decision.choice] : nil
            }
        }
        let changed = analysis.bumpsRemoved > 0 || (chosen.map { $0.error > 0.002 } ?? false)
        return Resolution(analysis: analysis, chosen: chosen, changed: changed)
    }

    private static func lines(_ points: [SIMD2<Float>]) -> [SketchShape] {
        points.indices.map { .line(points[$0], points[($0 + 1) % points.count]) }
    }

    // MARK: 3D bodies

    struct BodyResult {
        var meshes: [UUID: RenderMesh]
        var outcome: TouchUpOutcome
        /// Colours for existing bodies and new bodies to add (for example rails under a slab).
        var styles: [UUID: PartStyle] = [:]
        var additions: [(mesh: RenderMesh, style: PartStyle?)] = []
    }

    /// What happened to one body.
    struct BodyReport {
        var findings: MeshFindings
        var mesh: RenderMesh?
    }

    func touchUp(bodies: [(id: UUID, mesh: RenderMesh)], styles existing: [UUID: PartStyle] = [:]) async -> BodyResult {
        var meshes: [UUID: RenderMesh] = [:]
        var reports: [MeshFindings] = []
        for body in bodies {
            let report = await touchUp(body: body.mesh)
            reports.append(report.findings)
            if let mesh = report.mesh { meshes[body.id] = mesh }
        }
        // Then the parts together, whatever the design is.
        var assembly = AssemblyResult()
        var finish = FinishResult()
        var kind = ""
        let working = bodies.map { (id: $0.id, mesh: meshes[$0.id] ?? $0.mesh) }
        if let scene = DesignScene.build(from: working) {
            var plan = DesignRegularizer.heuristicPlan(for: scene)
            if let proposed = await advisor.plan(description: scene.description),
               let checked = DesignIntent.validated(proposed, partSizes: scene.partSizes) {
                plan = checked
            }
            assembly = DesignRegularizer.apply(plan, to: scene)
            kind = plan.kind
            for (id, mesh) in assembly.meshes { meshes[id] = mesh }
            // Finish on the tidied layout, so rounding and rails follow the symmetric parts.
            let tidy = bodies.map { (id: $0.id, mesh: meshes[$0.id] ?? $0.mesh) }
            if let tidyScene = DesignScene.build(from: tidy) {
                let groupIDs = plan.groups.map { $0.members.map { scene.parts[$0].id } }
                finish = DesignFinish.finish(tidyScene, plan: plan, groupIDs: groupIDs, existing: existing)
            }
        }
        for (id, mesh) in finish.meshes { meshes[id] = mesh }
        var result = BodyResult(
            meshes: meshes,
            outcome: Self.outcome(for: reports, changedParts: meshes.count, notes: assembly.notes, kind: kind, finishing: finish.notes)
        )
        result.styles = finish.styles
        result.additions = finish.additions
        return result
    }

    /// An extruded body has its outline read like a sketch (bumps out, corners snapped); anything
    /// else, and any body whose outline was already clean, gets the general mesh repair.
    func touchUp(body mesh: RenderMesh) async -> BodyReport {
        var findings = MeshFindings(shapeGuess: MeshTouchUp.shapeGuess(mesh))
        if let profile = MeshTouchUp.prismProfile(of: mesh) {
            var loops: [[SIMD2<Float>]] = []
            var changed = false
            for (index, loop) in profile.loops.enumerated() {
                let resolution = await resolve(loop, quadTolerance: 22)
                if let kind = resolution.chosen?.kind {
                    if findings.shapeGuess == nil { findings.shapeGuess = kind.rawValue }
                    if resolution.changed { findings.outlineReadings.append(index == 0 ? kind.rawValue : "\(kind.rawValue) hole") }
                }
                if resolution.changed {
                    changed = true
                    findings.outlineBumps += resolution.analysis.bumpsRemoved
                    loops.append(resolution.points)
                } else {
                    loops.append(loop)
                }
            }
            let pattern = HolePattern.regularise(loops)
            if pattern.changed {
                loops = pattern.loops
                changed = true
                findings.outlineReadings.append("symmetric pattern of identical holes")
            }
            if changed, let rebuilt = MeshTouchUp.rebuildPrism(profile, loops: loops) {
                return BodyReport(findings: findings, mesh: rebuilt)
            }
            findings.outlineBumps = 0
            findings.outlineReadings = []
        }
        let repaired = MeshTouchUp.repair(mesh)
        findings.spikes = repaired.findings.spikes
        findings.patchVertices = repaired.findings.patchVertices
        findings.flips = repaired.findings.flips
        findings.collapses = repaired.findings.collapses
        findings.degenerate = repaired.findings.degenerate
        return BodyReport(findings: findings, mesh: findings.isClean ? nil : repaired.mesh)
    }

    static func outcome(for reports: [MeshFindings], changedParts: Int, notes: [String] = [], kind: String = "", finishing: [String] = []) -> TouchUpOutcome {
        func total(_ value: KeyPath<MeshFindings, Int>) -> Int { reports.reduce(0) { $0 + $1[keyPath: value] } }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        guard changedParts > 0 || !finishing.isEmpty else {
            let known = reports.compactMap(\.shapeGuess)
            guard !known.isEmpty else { return TouchUpOutcome(message: unknownMessage, changed: false) }
            let names = Array(Set(known)).sorted().joined(separator: ", ")
            return TouchUpOutcome(message: "Nothing to touch up. Checked \(plural(reports.count, "part")) (\(names)) and found no bumps or slivers.", changed: false)
        }
        var parts: [String] = []
        let outline = total(\.outlineBumps)
        let readings = reports.flatMap(\.outlineReadings)
        if outline > 0 || !readings.isEmpty {
            var text = "cleaned an outline"
            if outline > 0 { text += ", removing \(plural(outline, "bump"))" }
            if !readings.isEmpty { text += ", snapped to a \(readings.joined(separator: " and a "))" }
            parts.append(text)
        }
        let bumps = total(\.spikes) + total(\.patchVertices)
        if bumps > 0 { parts.append("flattened \(plural(bumps, "bump"))") }
        let slivers = total(\.flips) + total(\.collapses)
        if slivers > 0 { parts.append("re-meshed \(plural(slivers, "sliver triangle"))") }
        if total(\.degenerate) > 0 { parts.append("removed \(plural(total(\.degenerate), "degenerate triangle"))") }
        parts += notes
        var message = ""
        if !parts.isEmpty { message = "Touched up \(plural(max(changedParts, 1), "part")): " + parts.joined(separator: "; ") + "." }
        if !finishing.isEmpty {
            let lead = DesignIntent.isGeneric(kind) ? "Finished it" : "Finished it as a \(kind)"
            message += (message.isEmpty ? "" : " ") + lead + ": " + finishing.joined(separator: "; ") + "."
        }
        return TouchUpOutcome(message: message, changed: true)
    }
}
