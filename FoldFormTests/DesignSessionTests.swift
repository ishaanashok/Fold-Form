import XCTest
@testable import FoldForm

@MainActor
final class DesignSessionTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormSessionTests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func setUpSession(width: @escaping () -> Double = { 0.2 }, debounce: TimeInterval = 0.05) throws -> (DesignLibrary, DesignSession, UUID, () -> Int) {
        let library = DesignLibrary(store: DesignStore(root: root))
        let design = try XCTUnwrap(library.createDesign(template: .box))
        let session = DesignSession(designID: design.id, library: library, debounce: debounce)
        var captures = 0
        session.capture = {
            captures += 1
            return DesignCapture(bodies: [DesignBody(mesh: GeometryBuilder.box(width: width(), height: 0.1, depth: 0.1), style: nil)], corner: .fillet, camera: nil)
        }
        return (library, session, design.id, { captures })
    }

    func testChangeSavesAfterTheDebounce() async throws {
        let (library, session, id, _) = try setUpSession()
        let before = library.designs[0].modifiedAt
        session.contentChanged()
        XCTAssertTrue(session.isDirty)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(session.isDirty)
        XCTAssertGreaterThanOrEqual(library.designs.first { $0.id == id }!.modifiedAt, before)
        XCTAssertEqual(try library.open(id).meshes.count, 1)
    }

    func testRapidChangesCoalesceIntoOneSave() async throws {
        let (_, session, _, captureCount) = try setUpSession()
        for _ in 0..<10 { session.contentChanged() }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(captureCount(), 1)
    }

    func testCloseSavesPendingChangesImmediately() throws {
        let (library, session, id, _) = try setUpSession(width: { 0.5 }, debounce: 60)
        session.contentChanged()
        session.close()
        XCTAssertFalse(session.isDirty)
        let mesh = try library.open(id).meshes[0]
        XCTAssertEqual(mesh.boundingBox.max.x - mesh.boundingBox.min.x, 0.5, accuracy: 1e-4)
    }

    func testCloseWithoutChangesDoesNotTouchTheDesign() throws {
        let (library, session, id, captureCount) = try setUpSession(debounce: 60)
        let before = library.designs.first { $0.id == id }!.modifiedAt
        session.close()
        XCTAssertEqual(captureCount(), 0)
        XCTAssertEqual(library.designs.first { $0.id == id }!.modifiedAt, before)
    }

    func testAnEmptyCaptureKeepsTheChangePendingAndTheOldSave() throws {
        let library = DesignLibrary(store: DesignStore(root: root))
        let design = try XCTUnwrap(library.createDesign(template: .box))
        let session = DesignSession(designID: design.id, library: library, debounce: 60)
        session.capture = { nil }
        session.contentChanged()
        session.saveNow()
        XCTAssertTrue(session.isDirty, "nothing was saved, so the change is still pending")
        XCTAssertFalse(try library.open(design.id).meshes.isEmpty)
    }
}
