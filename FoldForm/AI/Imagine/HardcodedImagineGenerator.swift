import Foundation

/// Stands in for the Imagine backend with two fixed designs: a table and a chair.
/// Nothing leaves the device. It waits like a network round trip so the sheet shows
/// the same "Planning features…" progress, then returns a plan that goes through the
/// normal validator and executor.
///
/// Choice: a prompt that mentions "chair" gets the chair. Otherwise the first request
/// gets the table, and any request after the table is in the scene gets the chair.
actor HardcodedImagineGenerator: ImagineGenerating {
    enum Design: Equatable { case table, chair }

    private let latency: Duration
    /// Body count just before the table was added, so an undone table is built again.
    private var tableBuiltAt: Int?

    init(latency: Duration = .milliseconds(2600)) {
        self.latency = latency
    }

    func generate(_ request: ImagineRequest) async throws -> ImaginePlan {
        let design = choose(for: request)
        try await Task.sleep(for: latency)
        if design == .table { tableBuiltAt = request.bodyCount }
        let extent = Self.extent(from: request.designDescription)
        return design == .table ? Self.table(beside: extent) : Self.chair(beside: extent)
    }

    func choose(for request: ImagineRequest) -> Design {
        if request.prompt.lowercased().contains("chair") { return .chair }
        let hasTable = tableBuiltAt.map { request.bodyCount >= $0 + Self.tableParts } ?? false
        return hasTable ? .chair : .table
    }

    // MARK: Designs (centimetres, measured from the middle of the current design)

    private static let tableParts = 5
    private static let gap: Double = 2

    /// A 16 × 10 cm top on four legs, 8 cm tall, standing to the right of the design.
    static func table(beside extent: SIMD3<Double>) -> ImaginePlan {
        let (width, depth, height, top, leg, inset) = (16.0, 10.0, 8.0, 1.0, 1.0, 0.6)
        let floor = -extent.y / 2
        let cx = extent.x / 2 + gap + width / 2
        let legX = width / 2 - inset - leg / 2
        let legZ = depth / 2 - inset - leg / 2
        let legHeight = height - top
        var steps = [box("tableTop", width, top, depth, at: [cx, floor + height - top / 2, 0])]
        for (i, (sx, sz)) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)].enumerated() {
            steps.append(box("tableLeg\(i + 1)", leg, legHeight, leg, at: [cx + sx * legX, floor + legHeight / 2, sz * legZ]))
        }
        return ImaginePlan(
            assumptions: [
                ImagineAssumption(name: "Table width", value: format(width), unit: "cm"),
                ImagineAssumption(name: "Table depth", value: format(depth), unit: "cm"),
                ImagineAssumption(name: "Table height", value: format(height), unit: "cm"),
                ImagineAssumption(name: "Leg thickness", value: format(leg), unit: "cm"),
            ],
            steps: steps
        )
    }

    /// A 6 × 6 cm seat on four legs with a backrest, facing back towards the design on its left.
    static func chair(beside extent: SIMD3<Double>) -> ImaginePlan {
        let (seat, seatHeight, seatThickness, leg, inset, back, backHeight) = (6.0, 5.0, 0.8, 0.8, 0.4, 0.8, 6.0)
        let floor = -extent.y / 2
        let cx = extent.x / 2 + gap + seat / 2
        let legHeight = seatHeight - seatThickness
        let legOffset = seat / 2 - inset - leg / 2
        var steps = [box("chairSeat", seat, seatThickness, seat, at: [cx, floor + seatHeight - seatThickness / 2, 0])]
        for (i, (sx, sz)) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)].enumerated() {
            steps.append(box("chairLeg\(i + 1)", leg, legHeight, leg, at: [cx + sx * legOffset, floor + legHeight / 2, sz * legOffset]))
        }
        steps.append(box("chairBack", back, backHeight, seat, at: [cx + seat / 2 - back / 2, floor + seatHeight + backHeight / 2, 0]))
        return ImaginePlan(
            assumptions: [
                ImagineAssumption(name: "Seat size", value: format(seat), unit: "cm"),
                ImagineAssumption(name: "Seat height", value: format(seatHeight), unit: "cm"),
                ImagineAssumption(name: "Backrest height", value: format(backHeight), unit: "cm"),
                ImagineAssumption(name: "Leg thickness", value: format(leg), unit: "cm"),
            ],
            steps: steps
        )
    }

    private static func format(_ value: Double) -> String { String(format: "%g", value) }

    private static func box(_ name: String, _ width: Double, _ height: Double, _ depth: Double, at centre: SIMD3<Double>) -> ImagineStep {
        ImagineStep(as: name, op: "add_box", args: [
            "width": .number(width), "height": .number(height), "depth": .number(depth),
            "x": .number(centre.x), "y": .number(centre.y), "z": .number(centre.z),
            "unit": .string("cm"),
        ], target: nil)
    }

    /// Reads the design's size (in cm) from the first line of `DesignScene.description`,
    /// falling back to the starting plate.
    static func extent(from description: String) -> SIMD3<Double> {
        let pattern = /The design is ([\d.]+) mm wide \(x\), ([\d.]+) mm tall \(y, up\) and ([\d.]+) mm deep/
        guard let match = description.firstMatch(of: pattern),
              let x = Double(match.1), let y = Double(match.2), let z = Double(match.3) else {
            return [12, 1.6, 5]
        }
        return [x, y, z] / 10
    }
}
