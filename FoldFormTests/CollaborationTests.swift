import XCTest
@testable import FoldForm

@MainActor
final class CollaborationTests: XCTestCase {
    private var file: URL!
    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("collab-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: file); super.tearDown() }

    private func service() -> LocalPreviewCollaborationService { LocalPreviewCollaborationService(fileURL: file) }

    func testItIsNeverConnected() {
        XCTAssertFalse(service().isConnected)
        XCTAssertEqual(LocalPreviewCollaborationService.previewBanner, "Preview: not connected to a server")
    }

    func testInviteStoresLocallyAndPersists() throws {
        let design = UUID()
        let s = service()
        let person = try s.invite(email: "ava@example.com", role: .editor, to: design)
        XCTAssertEqual(person.name, "Ava")
        XCTAssertEqual(s.collaborators(for: design).map(\.email), ["ava@example.com"])
        XCTAssertEqual(service().collaborators(for: design), [person], "a new instance reads the same file")
        XCTAssertEqual(s.sharedDesignIDs(), [design])
    }

    func testInvalidAndDuplicateEmailsAreRejected() throws {
        let design = UUID()
        let s = service()
        for bad in ["", "   ", "ava", "ava@", "@example.com", "a b@example.com", "ava@example"] {
            XCTAssertThrowsError(try s.invite(email: bad, role: .viewer, to: design), bad) { XCTAssertEqual($0 as? CollaborationError, .invalidEmail) }
        }
        _ = try s.invite(email: "Ava@Example.com", role: .viewer, to: design)
        XCTAssertThrowsError(try s.invite(email: " ava@example.COM ", role: .editor, to: design)) { XCTAssertEqual($0 as? CollaborationError, .alreadyInvited) }
        XCTAssertEqual(s.collaborators(for: design).count, 1)
        _ = try s.invite(email: "ava@example.com", role: .viewer, to: UUID())   // the same person on another design is fine
    }

    func testRoleChangeAndRemove() throws {
        let design = UUID()
        let s = service()
        let p = try s.invite(email: "ben@example.com", role: .viewer, to: design)
        s.setRole(.editor, for: p.id, in: design)
        XCTAssertEqual(s.collaborators(for: design)[0].role, .editor)
        s.remove(p.id, from: design)
        XCTAssertTrue(s.collaborators(for: design).isEmpty)
        XCTAssertTrue(s.sharedDesignIDs().isEmpty)
    }

    func testActivityIsAlwaysLabelledSampleAndOnlyForInvitedPeople() throws {
        let design = UUID()
        let s = service()
        XCTAssertTrue(s.activity(for: design).isEmpty, "no people, no activity: nothing is invented")
        _ = try s.invite(email: "cy@example.com", role: .editor, to: design)
        let activity = s.activity(for: design)
        XCTAssertFalse(activity.isEmpty)
        XCTAssertTrue(activity.allSatisfy(\.isSample))
        XCTAssertTrue(activity.allSatisfy { $0.who == "Cy" })
    }

    func testCorruptFileStartsEmptyInsteadOfCrashing() throws {
        try Data("nope".utf8).write(to: file)
        XCTAssertTrue(service().sharedDesignIDs().isEmpty)
    }

    func testLibrarySharedFilterUsesTheService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldFormCollabLibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = service()
        let library = DesignLibrary(store: DesignStore(root: root), collaboration: s)
        let d = try XCTUnwrap(library.createDesign(template: .box))
        _ = library.createDesign(template: .box)
        _ = try s.invite(email: "dee@example.com", role: .viewer, to: d.id)
        library.refreshShared()
        library.query.filter = .shared
        XCTAssertEqual(library.visibleDesigns.map(\.id), [d.id])
    }
}
