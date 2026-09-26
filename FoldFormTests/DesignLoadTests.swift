import XCTest
@testable import FoldForm

@MainActor
final class DesignLoadTests: XCTestCase {
    func testLoadedDesignBecomesBodiesWithColoursByPosition() {
        let a = GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05)
        let b = GeometryBuilder.cylinder(radius: 0.01, height: 0.04)
        let model = AppModel(loaded: LoadedDesign(meshes: [a, b], styles: [nil, Palette.style("red")], corner: .sharp, camera: nil))
        let studio = model.document.partStudio
        XCTAssertEqual(studio.orderedBodyIDs.count, 2)
        XCTAssertEqual(studio.body(studio.orderedBodyIDs[0])?.mesh, a)
        XCTAssertEqual(studio.body(studio.orderedBodyIDs[1])?.mesh, b)
        XCTAssertNil(model.partStyles[studio.orderedBodyIDs[0]])
        XCTAssertEqual(model.partStyles[studio.orderedBodyIDs[1]]?.name, "red")
    }

    func testEmptyLoadFallsBackToTheDefaultPlate() {
        let model = AppModel(loaded: LoadedDesign(meshes: [], styles: [], corner: .fillet, camera: nil))
        XCTAssertEqual(model.document.partStudio.orderedBodyIDs.count, 1)
        let onlyEmpty = AppModel(loaded: LoadedDesign(meshes: [.empty], styles: [nil], corner: .fillet, camera: nil))
        XCTAssertEqual(onlyEmpty.document.partStudio.orderedBodyIDs.count, 1)
    }

    func testSaveThenLoadReproducesTheBodies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormLoadTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DesignLibrary(store: DesignStore(root: root))
        let design = try XCTUnwrap(library.createDesign(template: .box))
        let a = GeometryBuilder.box(width: 0.12, height: 0.03, depth: 0.06)
        XCTAssertTrue(library.save(design.id, capture: DesignCapture(bodies: [DesignBody(mesh: a, style: Palette.style("oak"))], corner: .sharp, camera: nil)))
        let model = AppModel(loaded: try library.open(design.id))
        let id = try XCTUnwrap(model.document.partStudio.orderedBodyIDs.first)
        XCTAssertEqual(model.document.partStudio.body(id)?.mesh, a)
        XCTAssertEqual(model.partStyles[id]?.name, "oak")
    }
}
