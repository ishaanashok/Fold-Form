import XCTest
import simd
@testable import FoldForm

@MainActor
final class SelectionFilletTests: XCTestCase {
    private let size = CGSize(width: 900, height: 700)
    private let rig = CameraRig(target: .zero, yaw: 0.5, pitch: 0.35, distance: 0.16)

    private func box() -> RenderMesh {
        GeometryBuilder.box(width: 0.04, height: 0.02, depth: 0.03)
    }

    func testPickerFindsVisibleVertexAndEdgeAndClearsElsewhere() throws {
        let mesh = box()
        let corner = SIMD3<Float>(0.02, 0.01, 0.015)
        let screen = try XCTUnwrap(rig.project(corner, in: size))
        let vertex = MeshFeaturePicker.pick(mesh: mesh, rig: rig, size: size, point: screen)
        guard case .vertex(let picked) = vertex else { return XCTFail("Expected a vertex") }
        XCTAssertLessThan(simd_distance(picked, corner), 1e-5)

        let middle = SIMD3<Float>(0.02, 0, 0.015)
        let edgePoint = try XCTUnwrap(rig.project(middle, in: size))
        guard case .edge = MeshFeaturePicker.pick(mesh: mesh, rig: rig, size: size, point: edgePoint) else {
            return XCTFail("Expected an edge")
        }
        XCTAssertNil(MeshFeaturePicker.pick(mesh: mesh, rig: rig, size: size, point: CGPoint(x: 2, y: 2)))
    }

    func testViewportPressNearSilhouetteCornerStartsFillet() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let mesh = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let size = CGSize(width: 951, height: 669)
        let rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
        let corners = Set(mesh.positions).compactMap { rig.project($0, in: size) }
        let leftmost = try XCTUnwrap(corners.min { $0.x < $1.x })
        let nearOutside = CGPoint(x: leftmost.x - 6, y: leftmost.y)
        XCTAssertNil(viewport.part(at: nearOutside), "The regression point must miss the solid")
        XCTAssertNotNil(MeshFeaturePicker.pick(mesh: mesh, rig: rig, size: size, point: nearOutside))

        viewport.beginFillet(at: nearOutside)
        viewport.selectionBendChanged(.pi / 4)

        XCTAssertTrue(viewport.isBendingSelection, "A near-edge press should use the picker's screen tolerance")
    }

    func testTappedCornerStaysSelectedAfterTapAndBendsWithoutAHeldTouch() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let original = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let size = CGSize(width: 951, height: 669)
        let rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
        let corner = try XCTUnwrap(Set(original.positions).compactMap { rig.project($0, in: size) }.min { $0.x < $1.x })
        let tap = CGPoint(x: corner.x - 6, y: corner.y)
        let flatPreview = viewport.exportMesh()

        viewport.handleTap(at: tap)
        model.hingeInput.simulatorBendRadians = .pi / 4
        viewport.selectionBendChanged(model.hingeInput.bendAngleRadians)
        viewport.update(appModel: model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(viewport.isBendingSelection, "The selected corner must still receive hinge changes after the tap ends")
        XCTAssertNotEqual(viewport.exportMesh(), flatPreview, "The selected corner should show a live fillet preview")
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, original, "Bending should remain a preview until deselection or Hold")
    }

    func testTappingHighlightedCornerAgainCommitsOneFilletAndDeselects() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let original = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let size = CGSize(width: 951, height: 669)
        let rig = CameraRig(target: .zero, yaw: 0.66, pitch: 0.45, distance: 0.3)
        let corner = try XCTUnwrap(Set(original.positions).compactMap { rig.project($0, in: size) }.min { $0.x < $1.x })
        let tap = CGPoint(x: corner.x - 6, y: corner.y)

        viewport.handleTap(at: tap)
        model.hingeInput.simulatorBendRadians = .pi / 4
        viewport.selectionBendChanged(model.hingeInput.bendAngleRadians)
        viewport.handleTap(at: tap)

        XCTAssertFalse(viewport.isBendingSelection)
        XCTAssertTrue(viewport.isHolding)
        XCTAssertNotEqual(model.document.partStudio.body(id)?.mesh, original)
        viewport.undo()
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, original)
        XCTAssertFalse(viewport.canUndo)
    }

    func testRadiusUsesTheSameSnappedHingeBendAndStaysFinite() {
        let mesh = box()
        let selection = MeshFeatureSelection.edge(SIMD3(0.02, -0.01, 0.015), SIMD3(0.02, 0.01, 0.015))
        let raw = Double.pi - 89.4 * .pi / 180
        let bend = HingeInputManager.bend(fromHingeRadians: raw)
        XCTAssertEqual(bend, .pi / 2, accuracy: 1e-9)
        let radius = MeshFillet.radius(forBend: bend, mesh: mesh, selection: selection)
        XCTAssertGreaterThan(radius, 0)
        XCTAssertEqual(radius, MeshFillet.radius(forBend: HingeInputManager.snappedBend(HingeInputManager.clampedBend(.pi / 2)), mesh: mesh, selection: selection))
        XCTAssertEqual(MeshFillet.radius(forBend: .nan, mesh: mesh, selection: selection), 0)
        XCTAssertEqual(MeshFillet.radius(forBend: 0, mesh: mesh, selection: selection), 0)
    }

    func testEdgeAndVertexFilletsAreClosedFiniteAndShrinkCorner() throws {
        let mesh = box()
        let corner = SIMD3<Float>(0.02, 0.01, 0.015)
        for selection in [MeshFeatureSelection.edge(SIMD3(0.02, -0.01, 0.015), corner), .vertex(corner)] {
            let rounded = try XCTUnwrap(MeshFillet.make(mesh: mesh, selection: selection, bend: .pi / 2))
            XCTAssertTrue(rounded.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            XCTAssertGreaterThan(rounded.solidProperties?.volume ?? 0, 0)
            XCTAssertLessThan(rounded.solidProperties?.volume ?? .infinity, mesh.solidProperties!.volume)
            let topology = MeshTouchUp.Topology(rounded)
            XCTAssertTrue(topology.edgeFaces().values.allSatisfy { $0.count == 2 }, "Every mesh edge must have two faces")
        }
    }

    func testHoldAndReleaseMakesOneUndoStepAndRollbackRestoresDocument() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let before = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let box = before.boundingBox
        let corner = box.max
        let edge = MeshFeatureSelection.edge(SIMD3(box.max.x, box.min.y, box.max.z), corner)
        XCTAssertTrue(viewport.beginFillet(documentBodyID: id, selection: edge))
        XCTAssertTrue(viewport.holdSelectionFillet(bend: .pi / 2))
        let held = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        XCTAssertNotEqual(held, before)
        XCTAssertTrue(viewport.isHolding)
        viewport.selectionBendChanged(.pi / 3)
        XCTAssertTrue(viewport.isHolding)
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, held)
        viewport.selectionBendChanged(0)
        XCTAssertFalse(viewport.isHolding)
        viewport.endFillet()
        viewport.undo()
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, before)
        XCTAssertFalse(viewport.canUndo)

        let featureCount = model.document.partStudio.featureTree.features.count
        XCTAssertTrue(viewport.beginFillet(documentBodyID: id, selection: edge))
        viewport.endFillet(bend: .pi / 2, commit: false)
        XCTAssertEqual(model.document.partStudio.featureTree.features.count, featureCount)
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, before)
    }

    func testUndoWhileFilletIsHeldClearsItsLock() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let before = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let bounds = before.boundingBox
        let edge = MeshFeatureSelection.edge(
            SIMD3(bounds.max.x, bounds.min.y, bounds.max.z), bounds.max
        )
        XCTAssertTrue(viewport.beginFillet(documentBodyID: id, selection: edge))
        XCTAssertTrue(viewport.holdSelectionFillet(bend: .pi / 2))
        viewport.undo()
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, before)
        XCTAssertFalse(viewport.isHolding)
    }

    func testLongPressElsewhereClearsActiveFilletWithoutOpeningBodyMenu() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let mesh = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let box = mesh.boundingBox
        let edge = MeshFeatureSelection.edge(SIMD3(box.max.x, box.min.y, box.max.z), box.max)
        XCTAssertTrue(viewport.beginFillet(documentBodyID: id, selection: edge))
        viewport.selectionBendChanged(.pi / 4)
        viewport.handleLongPress(at: CGPoint(x: 475, y: 335))
        XCTAssertNil(viewport.menu)
        XCTAssertFalse(viewport.isBendingSelection)
    }

    func testSelectionCountsAsBendingOnlyAfterHingePassesFlatThreshold() throws {
        let model = AppModel()
        let viewport = ViewportEntities()
        viewport.update(appModel: model)
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        let mesh = try XCTUnwrap(model.document.partStudio.body(id)?.mesh)
        let box = mesh.boundingBox
        XCTAssertTrue(viewport.beginFillet(documentBodyID: id, selection: .edge(SIMD3(box.max.x, box.min.y, box.max.z), box.max)))
        XCTAssertFalse(viewport.isBendingSelection)
        viewport.selectionBendChanged(FoldSession.flatThresholdRadians * 0.5)
        XCTAssertFalse(viewport.isBendingSelection)
        viewport.selectionBendChanged(.pi / 4)
        XCTAssertTrue(viewport.isBendingSelection)
        viewport.endFillet(bend: .pi / 4, commit: false)
        XCTAssertFalse(viewport.isBendingSelection)
    }
}
