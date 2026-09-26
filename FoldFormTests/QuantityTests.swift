import XCTest
@testable import FoldForm

final class QuantityTests: XCTestCase {
    func testLengthUnitsConvertToMetres() {
        XCTAssertEqual(Quantity.length(3, unit: "cm") ?? 0, 0.03, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(30, unit: "mm") ?? 0, 0.03, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(30, unit: "millimeters") ?? 0, 0.03, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(2, unit: "Centimetres") ?? 0, 0.02, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(1, unit: "m") ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(2, unit: "inches") ?? 0, 0.0508, accuracy: 1e-6)
        XCTAssertEqual(Quantity.length(1, unit: "inch") ?? 0, 0.0254, accuracy: 1e-6)
    }

    func testThreeAndThirtyAreNotConfused() {
        XCTAssertNotEqual(Quantity.length(3, unit: "cm"), Quantity.length(30, unit: "cm"))
        XCTAssertNotEqual(Quantity.length(3, unit: "mm"), Quantity.length(3, unit: "cm"))
    }

    func testUnknownUnitAndNonFiniteValuesAreRejected() {
        XCTAssertNil(Quantity.length(3, unit: "parsecs"))
        XCTAssertNil(Quantity.length(.nan, unit: "mm"))
        XCTAssertNil(Quantity.length(.infinity, unit: "mm"))
    }

    func testAnglesConvertToRadians() {
        XCTAssertEqual(Quantity.angle(45, unit: "degrees") ?? 0, .pi / 4, accuracy: 1e-6)
        XCTAssertEqual(Quantity.angle(90, unit: "degree") ?? 0, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(Quantity.angle(1, unit: "radians") ?? 0, 1, accuracy: 1e-6)
        XCTAssertNil(Quantity.angle(10, unit: "cm"))
    }

    func testSpokenNumbers() {
        XCTAssertEqual(SpokenNumber.parse("three"), 3)
        XCTAssertEqual(SpokenNumber.parse("fifteen"), 15)
        XCTAssertEqual(SpokenNumber.parse("twenty five"), 25)
        XCTAssertEqual(SpokenNumber.parse("twenty-five"), 25)
        XCTAssertEqual(SpokenNumber.parse("two point five"), 2.5)
        XCTAssertEqual(SpokenNumber.parse("3.5"), 3.5)
        XCTAssertEqual(SpokenNumber.parse("30"), 30)
        XCTAssertEqual(SpokenNumber.parse("a hundred"), 100)
        XCTAssertEqual(SpokenNumber.parse("one hundred and twenty"), 120)
    }

    func testSpokenNegatives() {
        XCTAssertEqual(SpokenNumber.parse("minus ten"), -10)
        XCTAssertEqual(SpokenNumber.parse("negative 4"), -4)
        XCTAssertEqual(SpokenNumber.parse("-2.5"), -2.5)
    }

    func testNonNumbersAreNil() {
        XCTAssertNil(SpokenNumber.parse("banana"))
        XCTAssertNil(SpokenNumber.parse(""))
    }
}
