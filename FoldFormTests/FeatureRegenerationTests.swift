import XCTest
@testable import FoldForm

final class FeatureRegenerationTests: XCTestCase {
    func testSketchToExtrudeToHolePipelineRegenerates() {
        let studio = PartStudio()
        guard let plane = studio.featureTree.referencePlanes.first else { return XCTFail() }
        var sketch = Sketch(name: "S1", planeID: plane.id)
        sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: 0.1, height: 0.02, construction: false))
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))

        let extrude = ExtrudeFeature(name: "Extrude1", sketchID: sketch.id, parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new))
        studio.featureTree.append(extrude)
        studio.regenerate()

        XCTAssertEqual(extrude.regenerationState, .success)
        guard let bodyID = extrude.resultBodyID else { return XCTFail("extrude produced no body") }

        let hole = HoleFeature(name: "Hole1", targetBodyID: bodyID, definition: HoleDefinition(center: .zero, diameter: 0.01, type: .simple, throughAll: true))
        studio.featureTree.append(hole)
        studio.regenerate()

        XCTAssertEqual(hole.regenerationState, .success)
        XCTAssertNil(studio.lastRegenerationError)
    }

    func testEditingUpstreamSketchRegeneratesDownstreamExtrude() {
        let studio = PartStudio()
        guard let plane = studio.featureTree.referencePlanes.first else { return XCTFail() }
        var sketch = Sketch(name: "S1", planeID: plane.id)
        sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: 0.1, height: 0.02, construction: false))
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))
        let extrude = ExtrudeFeature(name: "Extrude1", sketchID: sketch.id, parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new))
        studio.featureTree.append(extrude)
        studio.regenerate()
        let firstCount = studio.body(extrude.resultBodyID!)?.mesh.positions.count

        sketch.entities = [.rectangle(id: UUID(), origin: .zero, width: 0.2, height: 0.04, construction: false)]
        studio.featureTree.updateSketch(sketch)
        studio.regenerate()
        let secondCount = studio.body(extrude.resultBodyID!)?.mesh.positions.count

        XCTAssertEqual(extrude.regenerationState, .success)
        XCTAssertEqual(firstCount, secondCount) // same topology, different dimensions — regenerated, not corrupted
    }

    func testDeletedUpstreamBodyFailsDownstreamFeatureWithoutCrashing() {
        let studio = PartStudio()
        guard let plane = studio.featureTree.referencePlanes.first else { return XCTFail() }
        var sketch = Sketch(name: "S1", planeID: plane.id)
        sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: 0.1, height: 0.02, construction: false))
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))
        let extrude = ExtrudeFeature(name: "Extrude1", sketchID: sketch.id, parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new))
        studio.featureTree.append(extrude)
        studio.regenerate()
        let hole = HoleFeature(name: "Hole1", targetBodyID: extrude.resultBodyID!, definition: HoleDefinition(center: .zero, diameter: 0.01))
        studio.featureTree.append(hole)

        studio.featureTree.remove(id: extrude.id)
        studio.regenerate()

        if case .failed = hole.regenerationState {
            // expected: reference lost, reported clearly, not silently dropped
        } else {
            XCTFail("expected hole to report a failed regeneration state")
        }
    }

    func testSuppressedFeatureIsSkipped() {
        let studio = PartStudio()
        guard let plane = studio.featureTree.referencePlanes.first else { return XCTFail() }
        var sketch = Sketch(name: "S1", planeID: plane.id)
        sketch.entities.append(.rectangle(id: UUID(), origin: .zero, width: 0.1, height: 0.02, construction: false))
        studio.featureTree.addSketch(sketch)
        studio.featureTree.append(SketchTreeFeature(name: "Sketch1", sketchID: sketch.id))
        let extrude = ExtrudeFeature(name: "Extrude1", sketchID: sketch.id, parameters: ExtrudeParameters(termination: .blind(distance: 0.05), resultType: .new))
        extrude.isSuppressed = true
        studio.featureTree.append(extrude)
        let bodies = studio.regenerate()

        XCTAssertEqual(extrude.regenerationState, .suppressed)
        XCTAssertTrue(bodies.isEmpty)
    }
}
