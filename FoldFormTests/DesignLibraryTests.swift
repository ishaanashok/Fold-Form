import XCTest
@testable import FoldForm

@MainActor
final class DesignLibraryTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormLibraryTests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func makeLibrary() -> DesignLibrary {
        DesignLibrary(store: DesignStore(root: root), now: { [unowned self] in self.clock })
    }
    private func tick(_ seconds: TimeInterval = 60) { clock = clock.addingTimeInterval(seconds) }

    func testCreateListsANamedDesignWithContentAndThumbnail() throws {
        let library = makeLibrary()
        let design = try XCTUnwrap(library.createDesign(template: .box))
        XCTAssertEqual(library.designs.map(\.id), [design.id])
        XCTAssertEqual(design.name, "Untitled design")
        XCTAssertGreaterThanOrEqual(design.partCount, 1)
        XCTAssertNotNil(library.thumbnail(for: design.id))
        XCTAssertFalse(try library.open(design.id).meshes.isEmpty)
    }

    func testNewDesignsGetUniqueNames() {
        let library = makeLibrary()
        let names = (0..<3).compactMap { _ in library.createDesign(template: .sheetPlate)?.name }
        XCTAssertEqual(names, ["Untitled design", "Untitled design 2", "Untitled design 3"])
    }

    func testRenameTrimsIgnoresBlankAndCapsLength() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        library.rename(d.id, to: "  Desk lamp  ")
        XCTAssertEqual(library.designs[0].name, "Desk lamp")
        library.rename(d.id, to: "   \n ")
        XCTAssertEqual(library.designs[0].name, "Desk lamp", "whitespace-only names are ignored")
        library.rename(d.id, to: String(repeating: "x", count: 200))
        XCTAssertEqual(library.designs[0].name.count, DesignLibrary.maxNameLength)
        library.rename(d.id, to: "Lamp 🪔")
        XCTAssertEqual(library.designs[0].name, "Lamp 🪔")
    }

    func testDuplicateIsIndependentAndNamedCopy() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        let copy = try XCTUnwrap(library.duplicate(d.id))
        XCTAssertEqual(copy.name, "Untitled design copy")
        XCTAssertNotEqual(copy.id, d.id)
        let second = try XCTUnwrap(library.duplicate(d.id))
        XCTAssertEqual(second.name, "Untitled design copy 2")
        XCTAssertEqual(library.designs.count, 3)
    }

    func testFavouriteAndFolders() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        library.setFavourite(d.id, true)
        let folder = try XCTUnwrap(library.createFolder("Furniture"))
        library.move(d.id, toFolder: folder.id)
        XCTAssertTrue(library.designs[0].isFavourite)
        XCTAssertEqual(library.folderName(library.designs[0].folderID), "Furniture")
        library.deleteFolder(folder.id)
        XCTAssertNil(library.designs[0].folderID, "designs in a deleted folder move back to the top level")
        XCTAssertTrue(library.folders.isEmpty)
    }

    func testEverythingSurvivesAFreshLibraryOnTheSameStore() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .cylinder))
        library.setFavourite(d.id, true)
        let folder = try XCTUnwrap(library.createFolder("Parts"))
        library.setSort(.name)
        let again = makeLibrary()
        XCTAssertEqual(again.designs.map(\.id), [d.id])
        XCTAssertTrue(again.designs[0].isFavourite)
        XCTAssertEqual(again.folders.map(\.id), [folder.id])
        XCTAssertEqual(again.query.sort, .name)
    }

    func testDeleteAndUndo() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        library.delete(d.id)
        XCTAssertTrue(library.designs.isEmpty)
        XCTAssertEqual(library.recentlyDeleted?.id, d.id)
        library.undoDelete()
        XCTAssertEqual(library.designs.map(\.id), [d.id])
        XCTAssertNil(library.recentlyDeleted)
        XCTAssertNoThrow(try library.open(d.id))
    }

    func testDeletedDesignsAreGoneAfterRelaunch() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        library.delete(d.id)
        let again = makeLibrary()   // launching empties the trash
        again.undoDelete()
        XCTAssertTrue(again.designs.isEmpty)
    }

    func testSaveUpdatesManifestAndRefusesEmptyCaptures() throws {
        let library = makeLibrary()
        let d = try XCTUnwrap(library.createDesign(template: .box))
        tick()
        let box = GeometryBuilder.box(width: 0.2, height: 0.1, depth: 0.1)
        let ok = library.save(d.id, capture: DesignCapture(bodies: [DesignBody(mesh: box, style: nil), DesignBody(mesh: box.translated(by: [0.3, 0, 0]), style: Palette.style("red"))], corner: .sharp, camera: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(library.designs[0].partCount, 2)
        XCTAssertEqual(library.designs[0].modifiedAt, clock)
        let loaded = try library.open(d.id)
        XCTAssertEqual(loaded.meshes.count, 2)
        XCTAssertEqual(loaded.corner, .sharp)

        XCTAssertFalse(library.save(d.id, capture: DesignCapture(bodies: [], corner: .fillet, camera: nil)))
        XCTAssertFalse(library.save(d.id, capture: DesignCapture(bodies: [DesignBody(mesh: .empty, style: nil)], corner: .fillet, camera: nil)))
        XCTAssertEqual(try library.open(d.id).meshes.count, 2, "an empty capture never overwrites a good save")
    }

    // MARK: Query

    private func manifest(_ name: String, edited: TimeInterval, created: TimeInterval = 0, fav: Bool = false, folder: UUID? = nil) -> DesignManifest {
        DesignManifest(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: created), modifiedAt: Date(timeIntervalSince1970: edited), isFavourite: fav, folderID: folder, partCount: 1, template: "Box")
    }

    func testSortsFiltersAndSearch() {
        let folder = UUID()
        let a = manifest("Bracket", edited: 300, created: 30, folder: folder)
        let b = manifest("table", edited: 200, created: 10, fav: true)
        let c = manifest("Chair", edited: 100, created: 20)
        let all = [a, b, c]
        func names(_ q: DesignQuery, shared: Set<UUID> = []) -> [String] { DesignLibrary.visible(all, query: q, sharedIDs: shared).map(\.name) }

        XCTAssertEqual(names(DesignQuery(sort: .lastEdited)), ["Bracket", "table", "Chair"])
        XCTAssertEqual(names(DesignQuery(sort: .name)), ["Bracket", "Chair", "table"])
        XCTAssertEqual(names(DesignQuery(sort: .created)), ["Bracket", "Chair", "table"])
        XCTAssertEqual(names(DesignQuery(filter: .favourites)), ["table"])
        XCTAssertEqual(names(DesignQuery(filter: .folder(folder))), ["Bracket"])
        XCTAssertEqual(names(DesignQuery(filter: .shared), shared: [c.id]), ["Chair"])
        XCTAssertEqual(names(DesignQuery(text: "  TAB ")), ["table"])
        XCTAssertEqual(names(DesignQuery(text: "zzz")), [])
    }

    func testEqualTimestampsSortStably() {
        let a = manifest("B", edited: 100), b = manifest("A", edited: 100), c = manifest("C", edited: 100)
        let first = DesignLibrary.visible([a, b, c], query: DesignQuery(), sharedIDs: []).map(\.name)
        let second = DesignLibrary.visible([c, a, b], query: DesignQuery(), sharedIDs: []).map(\.name)
        XCTAssertEqual(first, ["A", "B", "C"])
        XCTAssertEqual(first, second)
    }

    func testStatsCountEverything() throws {
        let library = makeLibrary()
        _ = library.createDesign(template: .box)
        let d = try XCTUnwrap(library.createDesign(template: .box))
        library.setFavourite(d.id, true)
        XCTAssertEqual(library.stats.designs, 2)
        XCTAssertEqual(library.stats.favourites, 1)
        XCTAssertEqual(library.stats.editedThisWeek, 2)
        XCTAssertGreaterThanOrEqual(library.stats.parts, 2)
        clock = clock.addingTimeInterval(8 * 24 * 3600)
        XCTAssertEqual(library.stats.editedThisWeek, 0)
    }
}
