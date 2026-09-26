import XCTest
@testable import FoldForm

@MainActor
final class VersionTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormVersionTests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func makeLibrary() -> DesignLibrary { DesignLibrary(store: DesignStore(root: root), now: { [unowned self] in self.clock }) }
    private func edit(_ library: DesignLibrary, _ id: UUID, width: Double) {
        clock = clock.addingTimeInterval(60)
        library.save(id, capture: DesignCapture(bodies: [DesignBody(mesh: GeometryBuilder.box(width: width, height: 0.1, depth: 0.1), style: nil)], corner: .fillet, camera: nil))
    }
    private func width(_ loaded: LoadedDesign) -> Float { loaded.meshes[0].boundingBox.max.x - loaded.meshes[0].boundingBox.min.x }

    func testSaveNamedVersionKeepsThatStateWhileTheDesignMovesOn() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.2)
        let v = try XCTUnwrap(library.saveVersion(of: d.id, name: "First cut", note: "before the holes", automatic: false))
        edit(library, d.id, width: 0.6)
        XCTAssertEqual(library.versions(of: d.id).map(\.name), ["First cut"])
        let restored = try library.restoreVersion(v.id, of: d.id)
        XCTAssertEqual(width(restored), 0.2, accuracy: 1e-4)
        XCTAssertEqual(width(try library.open(d.id)), 0.2, accuracy: 1e-4)
    }

    func testRestoreFirstKeepsTheCurrentStateAsAVersion() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.2)
        let v = try XCTUnwrap(library.saveVersion(of: d.id, name: "Small", note: "", automatic: false))
        edit(library, d.id, width: 0.6)
        _ = try library.restoreVersion(v.id, of: d.id)
        let safety = library.versions(of: d.id).first { $0.isAutomatic }
        XCTAssertNotNil(safety, "the state before the restore is kept, so the restore can be undone")
        let back = try library.restoreVersion(try XCTUnwrap(safety).id, of: d.id)
        XCTAssertEqual(width(back), 0.6, accuracy: 1e-4)
    }

    func testCheckpointOnlyWhenTheDesignChanged() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.2)
        library.checkpointIfChanged(d.id)
        library.checkpointIfChanged(d.id)
        XCTAssertEqual(library.versions(of: d.id).count, 1, "an unchanged design is not checkpointed twice")
        edit(library, d.id, width: 0.3)
        library.checkpointIfChanged(d.id)
        XCTAssertEqual(library.versions(of: d.id).count, 2)
    }

    func testAutomaticVersionsArePrunedButNamedOnesStay() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.1)
        XCTAssertNotNil(library.saveVersion(of: d.id, name: "Keeper", note: "", automatic: false))
        for i in 0..<(DesignLibrary.maxAutomaticVersions + 5) {
            edit(library, d.id, width: 0.2 + Double(i) * 0.01)
            library.checkpointIfChanged(d.id)
        }
        let versions = library.versions(of: d.id)
        XCTAssertEqual(versions.filter(\.isAutomatic).count, DesignLibrary.maxAutomaticVersions)
        XCTAssertTrue(versions.contains { $0.name == "Keeper" })
    }

    func testDeletingAVersionFreesItsMeshesButNotSharedOnes() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.2)
        let v = try XCTUnwrap(library.saveVersion(of: d.id, name: "A", note: "", automatic: false))
        edit(library, d.id, width: 0.4)
        library.deleteVersion(v.id, of: d.id)
        XCTAssertTrue(library.versions(of: d.id).isEmpty)
        XCTAssertEqual(width(try library.open(d.id)), 0.4, accuracy: 1e-4)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: library.store.packageURL(d.id).appendingPathComponent("meshes").path)
        XCTAssertEqual(blobs.count, 1)
    }

    func testDuplicatingADesignDoesNotCopyItsVersions() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        edit(library, d.id, width: 0.2)
        _ = library.saveVersion(of: d.id, name: "A", note: "", automatic: false)
        let copy = try XCTUnwrap(library.duplicate(d.id))
        XCTAssertTrue(library.versions(of: copy.id).isEmpty)
        XCTAssertEqual(library.versions(of: d.id).count, 1)
    }

    func testCloseCheckpointsAChangedDesign() async throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        let session = DesignSession(designID: d.id, library: library, debounce: 60)
        session.capture = { DesignCapture(bodies: [DesignBody(mesh: GeometryBuilder.box(width: 0.9, height: 0.1, depth: 0.1), style: nil)], corner: .fillet, camera: nil) }
        session.onClosed = { [weak library] in library?.checkpointIfChanged(d.id) }
        session.contentChanged()
        session.close()
        XCTAssertEqual(library.versions(of: d.id).count, 1)
    }
}
