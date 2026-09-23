import XCTest
@testable import FoldForm

final class SheetMetalCalculatorTests: XCTestCase {
    func testZeroAngleGivesZeroBendValues() {
        let calc = SheetMetalCalculator(thickness: 1, insideBendRadius: 1.5, kFactor: 0.44, legOneLength: 40, legTwoLength: 40)
        let result = calc.calculate(bendAngleRadians: 0)
        XCTAssertEqual(result.bendAllowance, 0)
        XCTAssertEqual(result.bendDeduction, 0)
        XCTAssertEqual(result.flatLength, 80)
    }

    func testNinetyDegreeBendMatchesFormula() {
        let t = 1.0, r = 1.5, k = 0.44
        let calc = SheetMetalCalculator(thickness: t, insideBendRadius: r, kFactor: k, legOneLength: 40, legTwoLength: 40)
        let theta = Double.pi / 2
        let result = calc.calculate(bendAngleRadians: theta)
        let expectedBA = theta * (r + k * t)
        let expectedBD = 2 * (r + t) * tan(theta / 2) - expectedBA
        XCTAssertEqual(result.bendAllowance, expectedBA, accuracy: 1e-9)
        XCTAssertEqual(result.bendDeduction, expectedBD, accuracy: 1e-9)
        XCTAssertEqual(result.flatLength, 40 + 40 + expectedBA, accuracy: 1e-9)
    }

    func testInvalidInputsNeverProduceNaNOrInfinity() {
        let calc = SheetMetalCalculator(thickness: 0, insideBendRadius: 0, kFactor: 0.44, legOneLength: 10, legTwoLength: 10)
        let result = calc.calculate(bendAngleRadians: .pi / 2)
        XCTAssertFalse(result.bendAllowance.isNaN)
        XCTAssertFalse(result.bendAllowance.isInfinite)
        XCTAssertFalse(result.bendDeduction.isNaN)
        XCTAssertFalse(result.bendDeduction.isInfinite)
    }

    func testNegativeAngleClampsToZero() {
        let calc = SheetMetalCalculator(thickness: 1, insideBendRadius: 1.5, kFactor: 0.44, legOneLength: 40, legTwoLength: 40)
        let result = calc.calculate(bendAngleRadians: -0.5)
        XCTAssertEqual(result.bendAllowance, 0)
        XCTAssertEqual(result.bendDeduction, 0)
    }

    func testDemoBendLimitHeuristic() {
        XCTAssertEqual(SheetMetalCalculator.demoBendLimitRadians(bendRadius: 2.0, thickness: 1.0) * 180 / .pi, 90, accuracy: 1e-6)
        XCTAssertEqual(SheetMetalCalculator.demoBendLimitRadians(bendRadius: 1.2, thickness: 1.0) * 180 / .pi, 80, accuracy: 1e-6)
        XCTAssertEqual(SheetMetalCalculator.demoBendLimitRadians(bendRadius: 0.5, thickness: 1.0) * 180 / .pi, 70, accuracy: 1e-6)
    }
}
