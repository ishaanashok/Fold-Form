import Foundation

/// Pure sheet-metal math, no RealityKit dependency, unit-tested directly (see FoldFormTests).
/// Units: millimeters for lengths, radians for angles — matches plan section 6 exactly.
///
///     BA = θ × (R + K × t)
///     BD = 2 × (R + t) × tan(θ / 2) − BA
///
/// This is an educational simplified model, not a certified fabrication calculator.
struct SheetMetalCalculator {
    var thickness: Double        // t, mm
    var insideBendRadius: Double // R, mm
    var kFactor: Double = 0.44   // K
    var legOneLength: Double     // mm
    var legTwoLength: Double     // mm

    struct Result: Equatable {
        var bendAllowance: Double   // BA, mm
        var bendDeduction: Double   // BD, mm
        var flatLength: Double      // mm, using the tangent-to-tangent leg convention
    }

    /// - Parameter bendAngleRadians: θ, the bend angle in radians. 0 means flat.
    func calculate(bendAngleRadians theta: Double) -> Result {
        guard theta.isFinite, thickness.isFinite, insideBendRadius.isFinite, kFactor.isFinite,
              legOneLength.isFinite, legTwoLength.isFinite else {
            return Result(bendAllowance: 0, bendDeduction: 0, flatLength: 0)
        }
        let safeThickness = max(0, thickness)
        let safeRadius = max(0, insideBendRadius)
        let safeKFactor = min(max(0, kFactor), 1)
        let safeLegOne = max(0, legOneLength)
        let safeLegTwo = max(0, legTwoLength)
        let clampedTheta = max(0, theta)
        guard clampedTheta > 1e-6 else {
            return Result(bendAllowance: 0, bendDeduction: 0, flatLength: safeLegOne + safeLegTwo)
        }

        let ba = clampedTheta * (safeRadius + safeKFactor * safeThickness)
        let bd = 2 * (safeRadius + safeThickness) * tan(clampedTheta / 2) - ba

        guard ba.isFinite, bd.isFinite else {
            return Result(bendAllowance: 0, bendDeduction: 0, flatLength: safeLegOne + safeLegTwo)
        }

        let flatLength = safeLegOne + safeLegTwo + ba
        return Result(bendAllowance: ba, bendDeduction: bd, flatLength: flatLength)
    }

    /// Demo bend-limit heuristic (plan section 8) — explicitly not a material-failure claim.
    static func demoBendLimitRadians(bendRadius: Double, thickness: Double) -> Double {
        guard thickness > 0 else { return .pi / 2 }
        let ratio = bendRadius / thickness
        var limitDegrees = 90.0
        if ratio < 1.0 {
            limitDegrees -= 20
        } else if ratio < 1.5 {
            limitDegrees -= 10
        }
        limitDegrees = min(max(limitDegrees, 45), 90)
        return limitDegrees * .pi / 180
    }
}
