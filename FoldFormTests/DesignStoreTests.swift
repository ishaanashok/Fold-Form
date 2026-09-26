import XCTest
@testable import FoldForm

@MainActor
final class DesignStoreTests: XCTestCase {
    private var root: URL!
    private var store: DesignStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormStoreTests-\(UUID().uuidString)")
        store = DesignStore(root: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func manifest(_ name: String = "Table") -> DesignManifest {
        DesignManifest(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: 1_000), modifiedAt: Date(timeIntervalSince1970: 2_000), partCount: 1, template: "Box")
    }
    private func capture(_ width: Double = 0.1) -> DesignCapture {
        DesignCapture(bodies: [DesignBody(mesh: GeometryBuilder.box(width: width, height: 0.02, depth: 0.05), style: Palette.style("oak"))], corner: .sharp, camera: nil)
    }
    @discardableResult
    private func saved(_ m: DesignManifest, _ c: DesignCapture) throws -> DesignContent {
        let (content, blobs) = DesignContent.make(c)
        try store.save(m, content: content, blobs: blobs, thumbnail: Data([1, 2, 3]))
        return content
    }

    func testSaveListLoadRoundTrip() throws {
        let m = manifest()
        try saved(m, capture())
        let listing = store.listManifests()
        XCTAssertEqual(listing.manifests, [m])
        XCTAssertTrue(listing.unreadable.isEmpty)
        let loaded = try store.loadDesign(m.id)
        XCTAssertEqual(loaded.meshes, capture().bodies.map(\.mesh))
        XCTAssertEqual(loaded.styles.first??.name, "oak")
        XCTAssertEqual(loaded.corner, .sharp)
        XCTAssertEqual(store.thumbnailData(m.id), Data([1, 2, 3]))
    }

    func testResavingKeepsOnlyReferencedBlobs() throws {
        let m = manifest()
        try saved(m, capture(0.1))
        try saved(m, capture(0.2))
        let blobs = try FileManager.default.contentsOfDirectory(atPath: store.packageURL(m.id).appendingPathComponent("meshes").path)
        XCTAssertEqual(blobs.count, 1)
    }

    func testMissingBlobThrowsAndKeepsThePackage() throws {
        let m = manifest()
        let content = try saved(m, capture())
        let blob = store.packageURL(m.id).appendingPathComponent("meshes/\(content.bodies[0].meshHash).mesh")
        try FileManager.default.removeItem(at: blob)
        XCTAssertThrowsError(try store.loadDesign(m.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.packageURL(m.id).path))
        XCTAssertEqual(store.listManifests().manifests.count, 1, "the design still lists so it can be deleted")
    }

    func testAlteredBlobIsRejected() throws {
        let m = manifest()
        let content = try saved(m, capture())
        let blob = store.packageURL(m.id).appendingPathComponent("meshes/\(content.bodies[0].meshHash).mesh")
        var bytes = try Data(contentsOf: blob)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: blob)
        XCTAssertThrowsError(try store.loadDesign(m.id))
    }

    func testCorruptManifestIsReportedNotDeleted() throws {
        let m = manifest()
        try saved(m, capture())
        try Data("{ not json".utf8).write(to: store.packageURL(m.id).appendingPathComponent("manifest.json"))
        let listing = store.listManifests()
        XCTAssertTrue(listing.manifests.isEmpty)
        XCTAssertEqual(listing.unreadable, [m.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.packageURL(m.id).path))
    }

    func testTrashRestoreAndEmpty() throws {
        let m = manifest()
        try saved(m, capture())
        try store.moveToTrash(m.id)
        XCTAssertTrue(store.listManifests().manifests.isEmpty)
        try store.restoreFromTrash(m.id)
        XCTAssertEqual(store.listManifests().manifests.count, 1)
        try store.moveToTrash(m.id)
        store.emptyTrash()
        XCTAssertThrowsError(try store.restoreFromTrash(m.id))
    }

    func testDuplicateIsIndependent() throws {
        let m = manifest("Original")
        try saved(m, capture())
        var copy = m; copy.id = UUID(); copy.name = "Original copy"
        try store.duplicate(m.id, as: copy)
        XCTAssertEqual(Set(store.listManifests().manifests.map(\.name)), ["Original", "Original copy"])
        store.removePermanently(m.id)
        XCTAssertNoThrow(try store.loadDesign(copy.id))
    }

    func testLibraryFileDefaultsWhenMissingOrCorrupt() throws {
        XCTAssertEqual(store.loadLibraryFile(), LibraryFile())
        let file = LibraryFile(folders: [DesignFolder(id: UUID(), name: "Furniture", createdAt: Date(timeIntervalSince1970: 5))], sort: "name")
        try store.saveLibraryFile(file)
        XCTAssertEqual(store.loadLibraryFile(), file)
        try Data("garbage".utf8).write(to: root.appendingPathComponent("library.json"))
        XCTAssertEqual(store.loadLibraryFile(), LibraryFile())
    }
}
