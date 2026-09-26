# Dashboard and Design Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open FoldForm on a dashboard of saved designs (autosaved, with thumbnails, folders, favourites, search, sort, templates, stats), add real local version history, and add a clearly-labelled collaboration preview with no backend.

**Architecture:** A file-based `DesignStore` writes one package folder per design (manifest, content, content-hashed mesh blobs, thumbnail). `DesignLibrary` is the observable layer the UI reads. The existing editor (`RootView`, renamed `EditorView`) is created fresh per opened design from a `LoadedDesign`; a `DesignSession` autosaves it through hooks in `ViewportEntities.push`/`undo`. Version history reuses the same blobs. Collaboration sits behind a `CollaborationService` protocol with a local-only preview implementation.

**Tech Stack:** Swift 6 language mode, SwiftUI, RealityKit, CryptoKit, CoreGraphics (thumbnails), XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-25-dashboard-design.md`

## Global Constraints

- Storage root is `Application Support/FoldForm/` (`Designs/<id>.fold/`, `Trash/`, `library.json`, `collab-preview.json`).
- Undo history is NOT saved. A saved design is: bodies (after held folds), colours by body position, corner style, camera.
- Autosave debounce is 1.5 s; also save on background and when returning to the dashboard.
- Thumbnails are rendered in CoreGraphics from saved meshes, decimated above 40,000 triangles. No RealityKit screenshot.
- Delete asks for confirmation, moves the package to `Trash/`, and shows an Undo toast; `Trash/` is emptied on next launch.
- Automatic versions are capped at 20 (oldest pruned); named versions are never pruned automatically.
- No networking anywhere: no `URLSession`, no sockets, no share links. Every collaboration screen shows the banner text "Preview: not connected to a server"; sample data is labelled "Sample".
- App is portrait-only, iPhone (`TARGETED_DEVICE_FAMILY: "1"`), deployment target iOS 27.1, Swift 6.
- Do NOT run UI tests and do NOT drive the live simulator (standing rule). Verify with unit tests and a build only.
- Do NOT `git commit` or `git push` unless the user asks. The working tree accumulates the changes.
- Design names: trimmed, non-empty, max 80 characters.
- After adding files run `xcodegen generate` (the project includes the whole `FoldForm` folder).
- Test command (run in the background and poll the log; foreground runs time out):
  `xcodebuild -project FoldForm.xcodeproj -scheme FoldForm -destination 'platform=iOS Simulator,name=iPhone Duo' test -only-testing:FoldFormTests/<Class> > $SCRATCH/test.log 2>&1`
  where `$SCRATCH=/private/tmp/claude-501/-Users-murthy-Documents-FoldForm/0e2dcede-d452-4ce9-83e4-facc8dec5dce/scratchpad`.

### Deviations from the spec (deliberate, behaviour unchanged)

1. New designs store the template's meshes immediately, instead of "template only, no content until first edit". One load path, and the dashboard has a thumbnail from the start.
2. Atomicity is per-file atomic replace with blobs written first and `manifest.json` last, instead of building a temp folder and swapping it. A crash at any point leaves the previous complete state readable.
3. No `sharedWithCount` on the manifest. "Shared" is derived from the collaboration service.

## Review Focus

1. A design name that is only whitespace, or 200 characters long → rename ignores whitespace-only, and long names are cut to 80. (Task 5)
2. Opening a design whose mesh blob is missing or altered → an error, the package is kept, the dashboard still works. (Task 3)
3. Autosave firing when the viewport has no usable bodies → must not overwrite the previous good save with an empty design. (Task 5, 7)
4. Two designs with the same modified time → sort order is stable (name, then id), so cards don't shuffle. (Task 5)
5. Inviting an invalid or duplicate email, or the same person in different case → rejected with a clear message. (Task 12)

---

## File Structure

New in `FoldForm/Library/`: `MeshBlob.swift` (binary mesh coding + hashing), `DesignModels.swift` (manifest, folder, content, capture, loaded), `DesignStore.swift` (disk), `ThumbnailRenderer.swift`, `DesignLibrary.swift` (observable list + operations + query), `DesignSession.swift` (autosave), `CollaborationService.swift`.
New in `FoldForm/Dashboard/`: `DashboardView.swift`, `DesignCard.swift`, `StatsHeader.swift`, `FolderBar.swift`, `TemplatePicker.swift`, `VersionHistoryView.swift`, `ShareView.swift`.
Changed: `FoldFormApp.swift`, `AppModel.swift`, `RealityViewport.swift`, `FoldFormUITests/GestureUITests.swift` (launch argument only).
Tests in `FoldFormTests/`: `MeshBlobTests.swift`, `DesignModelsTests.swift`, `DesignStoreTests.swift`, `ThumbnailRendererTests.swift`, `DesignLibraryTests.swift`, `DesignSessionTests.swift`, `DesignLoadTests.swift`, `VersionTests.swift`, `CollaborationTests.swift`.

---

# Phase 1: Library

### Task 1: Mesh blob coding

**Files:**
- Create: `FoldForm/Library/MeshBlob.swift`
- Test: `FoldFormTests/MeshBlobTests.swift`

**Interfaces:**
- Produces: `enum MeshBlob { static func encode(_ mesh: RenderMesh) -> Data; static func decode(_ data: Data) throws -> RenderMesh; static func hash(of data: Data) -> String }`, `enum MeshBlobError: Error { case badMagic, truncated }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FoldForm

final class MeshBlobTests: XCTestCase {
    func testRoundTripPreservesEveryValue() throws {
        let mesh = GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05)
        let decoded = try MeshBlob.decode(MeshBlob.encode(mesh))
        XCTAssertEqual(decoded, mesh)
    }

    func testEmptyMeshRoundTrips() throws {
        XCTAssertEqual(try MeshBlob.decode(MeshBlob.encode(.empty)), .empty)
    }

    func testEqualMeshesHashTheSameAndDifferentOnesDoNot() {
        let a = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        let b = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        let c = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 2))
        XCTAssertEqual(MeshBlob.hash(of: a), MeshBlob.hash(of: b))
        XCTAssertNotEqual(MeshBlob.hash(of: a), MeshBlob.hash(of: c))
        XCTAssertEqual(MeshBlob.hash(of: a).count, 64)
    }

    func testTruncatedAndForeignDataThrow() {
        let data = MeshBlob.encode(GeometryBuilder.box(width: 1, height: 1, depth: 1))
        XCTAssertThrowsError(try MeshBlob.decode(data.prefix(data.count - 3)))
        XCTAssertThrowsError(try MeshBlob.decode(Data("nonsense-not-a-mesh".utf8)))
        XCTAssertThrowsError(try MeshBlob.decode(Data()))
    }
}
```

- [ ] **Step 2: Run to verify it fails** (`-only-testing:FoldFormTests/MeshBlobTests`). Expected: compile error, `MeshBlob` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import CryptoKit

enum MeshBlobError: Error { case badMagic, truncated }

/// A mesh as bytes: "FFM1", then three little-endian UInt32 counts (positions, normals, indices),
/// then the position floats, normal floats and index integers. Named on disk by its SHA-256.
enum MeshBlob {
    private static let magic = Array("FFM1".utf8)
    private static let headerSize = 16

    static func encode(_ mesh: RenderMesh) -> Data {
        var data = Data(magic)
        data.reserveCapacity(headerSize + (mesh.positions.count * 3 + mesh.normals.count * 3 + mesh.indices.count) * 4)
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: Float) { put(value.bitPattern) }
        put(UInt32(mesh.positions.count))
        put(UInt32(mesh.normals.count))
        put(UInt32(mesh.indices.count))
        for p in mesh.positions { put(p.x); put(p.y); put(p.z) }
        for n in mesh.normals { put(n.x); put(n.y); put(n.z) }
        for i in mesh.indices { put(i) }
        return data
    }

    static func decode(_ data: Data) throws -> RenderMesh {
        guard data.count >= headerSize else { throw data.count >= 4 && Array(data.prefix(4)) != magic ? MeshBlobError.badMagic : MeshBlobError.truncated }
        guard Array(data.prefix(4)) == magic else { throw MeshBlobError.badMagic }
        func word(at offset: Int) -> UInt32 {
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
                .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        let positionCount = Int(word(at: 4)), normalCount = Int(word(at: 8)), indexCount = Int(word(at: 12))
        // Checked up front so a corrupt count can never drive a huge allocation.
        guard data.count == headerSize + (positionCount * 3 + normalCount * 3 + indexCount) * 4 else { throw MeshBlobError.truncated }
        var offset = headerSize
        func float() -> Float { defer { offset += 4 }; return Float(bitPattern: word(at: offset)) }
        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(positionCount)
        for _ in 0..<positionCount { positions.append(SIMD3(float(), float(), float())) }
        var normals: [SIMD3<Float>] = []; normals.reserveCapacity(normalCount)
        for _ in 0..<normalCount { normals.append(SIMD3(float(), float(), float())) }
        var indices: [UInt32] = []; indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount { indices.append(word(at: offset)); offset += 4 }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: 4 tests pass.

### Task 2: Models (manifest, folder, content, capture, loaded)

**Files:**
- Create: `FoldForm/Library/DesignModels.swift`
- Test: `FoldFormTests/DesignModelsTests.swift`

**Interfaces:**
- Consumes: `MeshBlob` (Task 1), `PartStyle`/`Palette`, `CornerStyle`, `CameraRig`, `PartProfileKind`.
- Produces:
  - `struct DesignManifest: Codable, Identifiable, Equatable { id: UUID; name: String; createdAt: Date; modifiedAt: Date; isFavourite: Bool; folderID: UUID?; partCount: Int; template: String }`
  - `struct DesignFolder: Codable, Identifiable, Equatable { id: UUID; name: String; createdAt: Date }`
  - `struct DesignBody { var mesh: RenderMesh; var style: PartStyle? }`
  - `struct DesignCapture { var bodies: [DesignBody]; var corner: CornerStyle; var camera: CameraRig? }`
  - `struct LoadedDesign { var meshes: [RenderMesh]; var styles: [PartStyle?]; var corner: CornerStyle; var camera: CameraRig? }`
  - `struct DesignContent: Codable, Equatable { struct Body { meshHash: String; style: String? }; struct Camera { target: [Float]; yaw, pitch, distance, roll: Float }; var bodies: [Body]; var corner: String; var camera: Camera?; var meshHashes: Set<String> }`
  - `static func DesignContent.make(_ capture: DesignCapture) -> (content: DesignContent, blobs: [String: Data])`
  - `DesignContent.Camera.init(_ rig: CameraRig)`, `var rig: CameraRig`
  - `static func DesignContent.template(_ kind: PartProfileKind) -> DesignCapture` (`@MainActor`)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FoldForm

@MainActor
final class DesignModelsTests: XCTestCase {
    private func capture() -> DesignCapture {
        let box = GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05)
        return DesignCapture(
            bodies: [DesignBody(mesh: box, style: Palette.style("oak")), DesignBody(mesh: box.translated(by: [0, 0.05, 0]), style: nil)],
            corner: .sharp,
            camera: CameraRig(target: [0.1, 0.2, 0.3], yaw: 0.5, pitch: 0.4, distance: 0.7, roll: 0.1)
        )
    }

    func testContentRoundTripsThroughJSON() throws {
        let (content, _) = DesignContent.make(capture())
        let decoded = try JSONDecoder().decode(DesignContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.bodies.map(\.style), ["oak", nil])
        XCTAssertEqual(decoded.corner, "sharp")
        XCTAssertEqual(decoded.camera?.rig, capture().camera)
    }

    func testIdenticalMeshesShareOneBlob() {
        let box = GeometryBuilder.box(width: 1, height: 1, depth: 1)
        let (content, blobs) = DesignContent.make(DesignCapture(
            bodies: [DesignBody(mesh: box, style: nil), DesignBody(mesh: box, style: nil)], corner: .fillet, camera: nil))
        XCTAssertEqual(content.bodies.count, 2)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(content.meshHashes, Set(blobs.keys))
    }

    func testUnknownCornerAndStyleFallBackGracefully() {
        var content = DesignContent.make(capture()).content
        content.corner = "bevelled"
        content.bodies[0].style = "no-such-colour"
        let loaded = content.loaded(meshes: [.empty, .empty])
        XCTAssertEqual(loaded.corner, .fillet)
        XCTAssertNil(loaded.styles[0])
    }

    func testEveryTemplateHasBodies() {
        for kind in PartProfileKind.allCases {
            let template = DesignContent.template(kind)
            XCTAssertFalse(template.bodies.isEmpty, kind.rawValue)
            XCTAssertFalse(template.bodies[0].mesh.positions.isEmpty, kind.rawValue)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: types not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

struct DesignManifest: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var isFavourite: Bool = false
    var folderID: UUID?
    var partCount: Int
    /// The `PartProfileKind` the design was started from, for display only.
    var template: String
}

struct DesignFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
}

struct DesignBody {
    var mesh: RenderMesh
    var style: PartStyle?
}

/// Everything read from the live workbench that a save needs.
struct DesignCapture {
    var bodies: [DesignBody]
    var corner: CornerStyle
    var camera: CameraRig?
}

/// A design read back from disk, ready to build an editor from.
struct LoadedDesign {
    var meshes: [RenderMesh]
    /// Colour per body, by position (body ids are regenerated on load).
    var styles: [PartStyle?]
    var corner: CornerStyle
    var camera: CameraRig?
}

struct DesignContent: Codable, Equatable {
    struct Body: Codable, Equatable {
        var meshHash: String
        /// A `Palette` colour name, or nil for the default blue.
        var style: String?
    }
    struct Camera: Codable, Equatable {
        var target: [Float]
        var yaw: Float
        var pitch: Float
        var distance: Float
        var roll: Float

        init(_ rig: CameraRig) {
            target = [rig.target.x, rig.target.y, rig.target.z]
            yaw = rig.yaw; pitch = rig.pitch; distance = rig.distance; roll = rig.roll
        }

        var rig: CameraRig {
            let t = target.count == 3 ? SIMD3<Float>(target[0], target[1], target[2]) : .zero
            return CameraRig(target: t, yaw: yaw, pitch: pitch, distance: distance, roll: roll)
        }
    }

    var bodies: [Body]
    var corner: String
    var camera: Camera?

    var meshHashes: Set<String> { Set(bodies.map(\.meshHash)) }

    static func make(_ capture: DesignCapture) -> (content: DesignContent, blobs: [String: Data]) {
        var blobs: [String: Data] = [:]
        let bodies = capture.bodies.map { body -> Body in
            let data = MeshBlob.encode(body.mesh)
            let hash = MeshBlob.hash(of: data)
            blobs[hash] = data
            return Body(meshHash: hash, style: body.style?.name)
        }
        return (DesignContent(bodies: bodies, corner: capture.corner.rawValue, camera: capture.camera.map(Camera.init)), blobs)
    }

    func loaded(meshes: [RenderMesh]) -> LoadedDesign {
        LoadedDesign(
            meshes: meshes,
            styles: bodies.map { $0.style.flatMap(Palette.style) },
            corner: CornerStyle(rawValue: corner) ?? .fillet,
            camera: camera?.rig
        )
    }

    /// The starting shapes of a new design: the app's own quick-start geometry for the profile.
    @MainActor
    static func template(_ kind: PartProfileKind) -> DesignCapture {
        let document = CADDocument()
        document.loadQuickStartProfile(kind)
        let studio = document.partStudio
        let bodies = studio.orderedBodyIDs.compactMap { studio.body($0) }.map { DesignBody(mesh: $0.mesh, style: nil) }
        return DesignCapture(bodies: bodies, corner: .fillet, camera: nil)
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: 4 tests pass.

### Task 3: DesignStore (disk)

**Files:**
- Create: `FoldForm/Library/DesignStore.swift`
- Test: `FoldFormTests/DesignStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 and 2 types.
- Produces (`final class DesignStore`, non-actor, synchronous):
  - `init(root: URL = DesignStore.defaultRoot)`, `let root: URL`, `static var defaultRoot: URL`
  - `struct Listing { var manifests: [DesignManifest]; var unreadable: [UUID] }`
  - `func listManifests() -> Listing`
  - `func save(_ manifest: DesignManifest, content: DesignContent, blobs: [String: Data], thumbnail: Data?) throws`
  - `func writeManifest(_ manifest: DesignManifest) throws`
  - `func loadContent(_ id: UUID) throws -> DesignContent`
  - `func loadMeshes(_ content: DesignContent, for id: UUID) throws -> [RenderMesh]`
  - `func loadDesign(_ id: UUID) throws -> LoadedDesign`
  - `func replaceContent(_ content: DesignContent, for id: UUID) throws`
  - `func thumbnailData(_ id: UUID) -> Data?`, `func writeThumbnail(_ data: Data, for id: UUID) throws`
  - `func moveToTrash(_ id: UUID) throws`, `func restoreFromTrash(_ id: UUID) throws`, `func emptyTrash()`, `func removePermanently(_ id: UUID)`
  - `func duplicate(_ id: UUID, as manifest: DesignManifest) throws`
  - `func collectGarbage(for id: UUID)` (deletes mesh blobs no content or version references)
  - `func loadLibraryFile() -> LibraryFile`, `func saveLibraryFile(_ file: LibraryFile) throws` with `struct LibraryFile: Codable, Equatable { var folders: [DesignFolder] = []; var sort: String = "lastEdited" }`
  - `enum DesignStoreError: Error, Equatable { case notFound, corrupt(String) }`
  - Package layout helpers: `func packageURL(_ id: UUID) -> URL`, `func versionsURL(_ id: UUID) -> URL`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: `DesignStore` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum DesignStoreError: Error, Equatable {
    case notFound
    case corrupt(String)
}

struct LibraryFile: Codable, Equatable {
    var folders: [DesignFolder] = []
    var sort: String = "lastEdited"
}

/// Reads and writes design packages. Every file is replaced atomically, with mesh blobs written
/// before the content that refers to them and the manifest last, so a crash at any point leaves the
/// previous complete state readable.
final class DesignStore {
    struct Listing {
        var manifests: [DesignManifest]
        var unreadable: [UUID]
    }

    let root: URL
    private let fm = FileManager.default

    init(root: URL = DesignStore.defaultRoot) {
        self.root = root
        try? fm.createDirectory(at: designsURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoldForm", isDirectory: true)
    }

    var designsURL: URL { root.appendingPathComponent("Designs", isDirectory: true) }
    var trashURL: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    private var libraryFileURL: URL { root.appendingPathComponent("library.json") }

    func packageURL(_ id: UUID) -> URL { designsURL.appendingPathComponent("\(id.uuidString).fold", isDirectory: true) }
    func versionsURL(_ id: UUID) -> URL { packageURL(id).appendingPathComponent("versions", isDirectory: true) }
    private func trashedURL(_ id: UUID) -> URL { trashURL.appendingPathComponent("\(id.uuidString).fold", isDirectory: true) }
    private func meshesURL(_ id: UUID) -> URL { packageURL(id).appendingPathComponent("meshes", isDirectory: true) }
    private func manifestURL(_ id: UUID) -> URL { packageURL(id).appendingPathComponent("manifest.json") }
    private func contentURL(_ id: UUID) -> URL { packageURL(id).appendingPathComponent("content.json") }
    private func thumbnailURL(_ id: UUID) -> URL { packageURL(id).appendingPathComponent("thumbnail.png") }

    // MARK: JSON

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    // MARK: Listing

    func listManifests() -> Listing {
        let entries = (try? fm.contentsOfDirectory(at: designsURL, includingPropertiesForKeys: nil)) ?? []
        var listing = Listing(manifests: [], unreadable: [])
        for url in entries where url.pathExtension == "fold" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            if let manifest = try? decode(DesignManifest.self, from: url.appendingPathComponent("manifest.json")), manifest.id == id {
                listing.manifests.append(manifest)
            } else {
                listing.unreadable.append(id)
            }
        }
        return listing
    }

    // MARK: Saving

    func save(_ manifest: DesignManifest, content: DesignContent, blobs: [String: Data], thumbnail: Data?) throws {
        let id = manifest.id
        try fm.createDirectory(at: meshesURL(id), withIntermediateDirectories: true)
        for (hash, data) in blobs {
            let url = meshesURL(id).appendingPathComponent("\(hash).mesh")
            if !fm.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        try encode(content).write(to: contentURL(id), options: .atomic)
        if let thumbnail { try thumbnail.write(to: thumbnailURL(id), options: .atomic) }
        try encode(manifest).write(to: manifestURL(id), options: .atomic)
        collectGarbage(for: id)
    }

    func writeManifest(_ manifest: DesignManifest) throws {
        try encode(manifest).write(to: manifestURL(manifest.id), options: .atomic)
    }

    func replaceContent(_ content: DesignContent, for id: UUID) throws {
        try encode(content).write(to: contentURL(id), options: .atomic)
    }

    func writeThumbnail(_ data: Data, for id: UUID) throws {
        try data.write(to: thumbnailURL(id), options: .atomic)
    }

    func thumbnailData(_ id: UUID) -> Data? { try? Data(contentsOf: thumbnailURL(id)) }

    // MARK: Loading

    func loadContent(_ id: UUID) throws -> DesignContent {
        guard fm.fileExists(atPath: contentURL(id).path) else { throw DesignStoreError.notFound }
        do { return try decode(DesignContent.self, from: contentURL(id)) }
        catch { throw DesignStoreError.corrupt("content.json is unreadable") }
    }

    func loadMeshes(_ content: DesignContent, for id: UUID) throws -> [RenderMesh] {
        try content.bodies.map { body in
            let url = meshesURL(id).appendingPathComponent("\(body.meshHash).mesh")
            guard let data = try? Data(contentsOf: url) else { throw DesignStoreError.corrupt("a mesh file is missing") }
            guard MeshBlob.hash(of: data) == body.meshHash else { throw DesignStoreError.corrupt("a mesh file was altered") }
            do { return try MeshBlob.decode(data) }
            catch { throw DesignStoreError.corrupt("a mesh file is unreadable") }
        }
    }

    func loadDesign(_ id: UUID) throws -> LoadedDesign {
        let content = try loadContent(id)
        return content.loaded(meshes: try loadMeshes(content, for: id))
    }

    // MARK: Trash, duplicate, garbage

    func moveToTrash(_ id: UUID) throws {
        guard fm.fileExists(atPath: packageURL(id).path) else { throw DesignStoreError.notFound }
        try? fm.removeItem(at: trashedURL(id))
        try fm.moveItem(at: packageURL(id), to: trashedURL(id))
    }

    func restoreFromTrash(_ id: UUID) throws {
        guard fm.fileExists(atPath: trashedURL(id).path) else { throw DesignStoreError.notFound }
        try fm.moveItem(at: trashedURL(id), to: packageURL(id))
    }

    func emptyTrash() {
        for url in (try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    func removePermanently(_ id: UUID) { try? fm.removeItem(at: packageURL(id)) }

    func duplicate(_ id: UUID, as manifest: DesignManifest) throws {
        guard fm.fileExists(atPath: packageURL(id).path) else { throw DesignStoreError.notFound }
        try fm.copyItem(at: packageURL(id), to: packageURL(manifest.id))
        try? fm.removeItem(at: versionsURL(manifest.id))
        try writeManifest(manifest)
    }

    private struct ContentProbe: Decodable { var content: DesignContent }

    /// Deletes mesh blobs that neither the design nor any of its versions refers to.
    func collectGarbage(for id: UUID) {
        var referenced = Set<String>()
        if let content = try? loadContent(id) { referenced.formUnion(content.meshHashes) }
        for folder in (try? fm.contentsOfDirectory(at: versionsURL(id), includingPropertiesForKeys: nil)) ?? [] {
            if let probe = try? decode(ContentProbe.self, from: folder.appendingPathComponent("version.json")) {
                referenced.formUnion(probe.content.meshHashes)
            }
        }
        for url in (try? fm.contentsOfDirectory(at: meshesURL(id), includingPropertiesForKeys: nil)) ?? [] {
            if !referenced.contains(url.deletingPathExtension().lastPathComponent) { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Library file

    func loadLibraryFile() -> LibraryFile {
        (try? decode(LibraryFile.self, from: libraryFileURL)) ?? LibraryFile()
    }

    func saveLibraryFile(_ file: LibraryFile) throws {
        try encode(file).write(to: libraryFileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: 8 tests pass. (`testMissingBlobThrowsAndKeepsThePackage` covers Review Focus 2.)

### Task 4: Thumbnail renderer

**Files:**
- Create: `FoldForm/Library/ThumbnailRenderer.swift`
- Test: `FoldFormTests/ThumbnailRendererTests.swift`

**Interfaces:**
- Consumes: `RenderMesh`, `boundingBox`.
- Produces: `enum ThumbnailRenderer { struct Body { var mesh: RenderMesh; var rgb: SIMD3<Float> }; static let defaultRGB: SIMD3<Float>; static let triangleBudget = 40_000; static func render(_ bodies: [Body], size: CGSize = CGSize(width: 480, height: 360), scale: CGFloat = 2) -> UIImage? }`; returns nil when there is nothing to draw.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import FoldForm

final class ThumbnailRendererTests: XCTestCase {
    private func opaqueFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let drawn = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
        return Double(drawn) / Double(w * h)
    }

    func testBoxRendersSomethingThatDoesNotFillTheCanvas() throws {
        let body = ThumbnailRenderer.Body(mesh: GeometryBuilder.box(width: 0.1, height: 0.02, depth: 0.05), rgb: ThumbnailRenderer.defaultRGB)
        let image = try XCTUnwrap(ThumbnailRenderer.render([body]))
        XCTAssertEqual(image.size, CGSize(width: 480, height: 360))
        let fraction = opaqueFraction(image)
        XCTAssertGreaterThan(fraction, 0.05)
        XCTAssertLessThan(fraction, 0.9)
    }

    func testColourShowsInThePixels() throws {
        let red = ThumbnailRenderer.Body(mesh: GeometryBuilder.box(width: 0.1, height: 0.1, depth: 0.1), rgb: [0.9, 0.1, 0.1])
        let image = try XCTUnwrap(ThumbnailRenderer.render([red], size: CGSize(width: 100, height: 100), scale: 1))
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -50, y: -50, width: 100, height: 100))
        XCTAssertGreaterThan(px[0], px[2], "a red body reads red at the centre")
    }

    func testNothingToDrawGivesNil() {
        XCTAssertNil(ThumbnailRenderer.render([]))
        XCTAssertNil(ThumbnailRenderer.render([.init(mesh: .empty, rgb: [1, 1, 1])]))
    }

    func testHugeMeshIsDecimatedAndStillRenders() throws {
        var big = RenderMesh.empty
        for i in 0..<300 { big = RenderMesh.merged([big, GeometryBuilder.cylinder(radius: 0.01, height: 0.01, segments: 64).translated(by: [Float(i) * 0.002, 0, 0])]) }
        XCTAssertGreaterThan(big.indices.count / 3, ThumbnailRenderer.triangleBudget)
        XCTAssertNotNil(ThumbnailRenderer.render([.init(mesh: big, rgb: ThumbnailRenderer.defaultRGB)]))
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: `ThumbnailRenderer` not defined.

- [ ] **Step 3: Implement**

```swift
import UIKit
import simd

/// Draws a design as a flat-shaded picture, from a fixed three-quarter view, straight from its
/// meshes. No GPU or live scene needed, so it works headless and is testable.
enum ThumbnailRenderer {
    struct Body {
        var mesh: RenderMesh
        var rgb: SIMD3<Float>
    }

    static let defaultRGB = SIMD3<Float>(0.16, 0.42, 0.95)
    static let triangleBudget = 40_000

    private struct Triangle {
        var a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>
        var depth: Float
        var color: SIMD3<Float>
    }

    static func render(_ bodies: [Body], size: CGSize = CGSize(width: 480, height: 360), scale: CGFloat = 2) -> UIImage? {
        let drawable = bodies.filter { !$0.mesh.positions.isEmpty && $0.mesh.indices.count >= 3 }
        guard !drawable.isEmpty else { return nil }

        var lo = drawable[0].mesh.boundingBox.min, hi = drawable[0].mesh.boundingBox.max
        for body in drawable { let b = body.mesh.boundingBox; lo = simd_min(lo, b.min); hi = simd_max(hi, b.max) }
        let centre = (lo + hi) / 2

        let toCamera = simd_normalize(SIMD3<Float>(1.1, 0.85, 1.4))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), toCamera))
        let up = simd_cross(toCamera, right)
        let light = simd_normalize(toCamera + up * 0.6 + right * 0.3)

        let total = drawable.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        let step = max(1, total / triangleBudget + (total % triangleBudget == 0 ? 0 : 1))

        var triangles: [Triangle] = []
        triangles.reserveCapacity(min(total, triangleBudget + 1))
        for body in drawable {
            let mesh = body.mesh
            var t = 0
            while t + 2 < mesh.indices.count {
                let i0 = Int(mesh.indices[t]), i1 = Int(mesh.indices[t + 1]), i2 = Int(mesh.indices[t + 2])
                t += 3 * step
                guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
                let p0 = mesh.positions[i0] - centre, p1 = mesh.positions[i1] - centre, p2 = mesh.positions[i2] - centre
                let normal = simd_cross(p1 - p0, p2 - p0)
                let length = simd_length(normal)
                guard length > 1e-12 else { continue }
                let shade = 0.42 + 0.58 * abs(simd_dot(normal / length, light))
                func project(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(simd_dot(p, right), simd_dot(p, up)) }
                triangles.append(Triangle(
                    a: project(p0), b: project(p1), c: project(p2),
                    depth: simd_dot(p0 + p1 + p2, toCamera) / 3, color: body.rgb * shade))
            }
        }
        guard !triangles.isEmpty else { return nil }

        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for tri in triangles { for p in [tri.a, tri.b, tri.c] {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        } }
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        let fit = Float(min(size.width * 0.78 / CGFloat(spanX), size.height * 0.78 / CGFloat(spanY)))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        func screen(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat((p.x - midX) * fit), y: size.height / 2 - CGFloat((p.y - midY) * fit))
        }

        triangles.sort { $0.depth < $1.depth }   // far first, so nearer faces paint over them

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setLineJoin(.round)
            cg.setLineWidth(0.6)
            for tri in triangles {
                let color = UIColor(red: CGFloat(min(tri.color.x, 1)), green: CGFloat(min(tri.color.y, 1)), blue: CGFloat(min(tri.color.z, 1)), alpha: 1)
                cg.setFillColor(color.cgColor)
                cg.setStrokeColor(color.cgColor)   // a hairline in the same colour hides seams between triangles
                cg.beginPath()
                cg.move(to: screen(tri.a)); cg.addLine(to: screen(tri.b)); cg.addLine(to: screen(tri.c)); cg.closePath()
                cg.drawPath(using: .fillStroke)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: 4 tests pass.

### Task 5: DesignLibrary (observable operations, query)

**Files:**
- Create: `FoldForm/Library/DesignLibrary.swift`
- Test: `FoldFormTests/DesignLibraryTests.swift`

**Interfaces:**
- Consumes: `DesignStore`, `DesignContent.make/template`, `ThumbnailRenderer`, models.
- Produces (`@MainActor final class DesignLibrary: ObservableObject`):
  - `init(store: DesignStore = DesignStore(), now: @escaping () -> Date = Date.init)` (empties the trash)
  - `@Published private(set) var designs: [DesignManifest]`, `folders: [DesignFolder]`, `unreadable: [UUID]`
  - `@Published var query: DesignQuery`, `@Published private(set) var recentlyDeleted: DesignManifest?`, `@Published var lastError: String?`
  - `struct DesignQuery: Equatable { var text = ""; var sort: DesignSort = .lastEdited; var filter: DesignFilter = .all }`
  - `enum DesignSort: String, CaseIterable, Identifiable { case lastEdited, name, created; var title: String }`
  - `enum DesignFilter: Equatable { case all, favourites, shared, folder(UUID) }`
  - `struct DashboardStats: Equatable { var designs, parts, favourites, editedThisWeek: Int }`
  - `var visibleDesigns: [DesignManifest]`, `var stats: DashboardStats`
  - `static func visible(_ designs: [DesignManifest], query: DesignQuery, sharedIDs: Set<UUID>) -> [DesignManifest]`
  - `static let maxNameLength = 80`, `static func cleaned(_ name: String) -> String?`
  - `@discardableResult func createDesign(template: PartProfileKind) -> DesignManifest?`
  - `func rename(_ id: UUID, to name: String)`, `@discardableResult func duplicate(_ id: UUID) -> DesignManifest?`, `func setFavourite(_ id: UUID, _ on: Bool)`, `func move(_ id: UUID, toFolder folderID: UUID?)`
  - `func delete(_ id: UUID)`, `func undoDelete()`, `func dismissDeletionNotice()`, `func removeUnreadable(_ id: UUID)`
  - `@discardableResult func createFolder(_ name: String) -> DesignFolder?`, `func renameFolder(_ id: UUID, to name: String)`, `func deleteFolder(_ id: UUID)`
  - `@discardableResult func save(_ id: UUID, capture: DesignCapture) -> Bool`
  - `func open(_ id: UUID) throws -> LoadedDesign`, `func thumbnail(for id: UUID) -> UIImage?`, `func folderName(_ id: UUID?) -> String?`
  - `func setSort(_ sort: DesignSort)` (also persists to `library.json`)

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: `DesignLibrary` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import UIKit
import Combine

enum DesignSort: String, CaseIterable, Identifiable {
    case lastEdited, name, created
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastEdited: return "Last edited"
        case .name: return "Name"
        case .created: return "Date created"
        }
    }
}

enum DesignFilter: Equatable {
    case all, favourites, shared
    case folder(UUID)
}

struct DesignQuery: Equatable {
    var text = ""
    var sort: DesignSort = .lastEdited
    var filter: DesignFilter = .all
}

struct DashboardStats: Equatable {
    var designs = 0
    var parts = 0
    var favourites = 0
    var editedThisWeek = 0
}

/// Everything the dashboard shows and does. The only type that talks to the `DesignStore`.
@MainActor
final class DesignLibrary: ObservableObject {
    static let maxNameLength = 80

    @Published private(set) var designs: [DesignManifest] = []
    @Published private(set) var folders: [DesignFolder] = []
    @Published private(set) var unreadable: [UUID] = []
    @Published var query = DesignQuery()
    @Published private(set) var recentlyDeleted: DesignManifest?
    @Published var lastError: String?

    let store: DesignStore
    private let now: () -> Date
    private let thumbnails = NSCache<NSString, UIImage>()

    init(store: DesignStore = DesignStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        store.emptyTrash()
        reload()
        let file = store.loadLibraryFile()
        folders = file.folders
        query.sort = DesignSort(rawValue: file.sort) ?? .lastEdited
    }

    private func reload() {
        let listing = store.listManifests()
        designs = listing.manifests
        unreadable = listing.unreadable
    }

    // MARK: Query

    var visibleDesigns: [DesignManifest] { Self.visible(designs, query: query, sharedIDs: sharedIDs) }

    /// Designs shared with someone. Filled in by the collaboration preview (phase 3).
    var sharedIDs: Set<UUID> = []

    static func visible(_ designs: [DesignManifest], query: DesignQuery, sharedIDs: Set<UUID>) -> [DesignManifest] {
        var result = designs.filter { design in
            switch query.filter {
            case .all: return true
            case .favourites: return design.isFavourite
            case .shared: return sharedIDs.contains(design.id)
            case .folder(let id): return design.folderID == id
            }
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(text) } }
        func byName(_ a: DesignManifest, _ b: DesignManifest) -> Bool? {
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return nil
            }
        }
        result.sort { a, b in
            switch query.sort {
            case .lastEdited: if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            case .created: if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .name: break
            }
            if let ordered = byName(a, b) { return ordered }
            return a.id.uuidString < b.id.uuidString
        }
        return result
    }

    var stats: DashboardStats {
        let weekAgo = now().addingTimeInterval(-7 * 24 * 3600)
        return DashboardStats(
            designs: designs.count,
            parts: designs.reduce(0) { $0 + $1.partCount },
            favourites: designs.filter(\.isFavourite).count,
            editedThisWeek: designs.filter { $0.modifiedAt >= weekAgo }.count
        )
    }

    func setSort(_ sort: DesignSort) {
        query.sort = sort
        persistLibraryFile()
    }

    func folderName(_ id: UUID?) -> String? { id.flatMap { id in folders.first { $0.id == id }?.name } }

    // MARK: Names

    static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxNameLength))
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(designs.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Designs

    @discardableResult
    func createDesign(template: PartProfileKind) -> DesignManifest? {
        let capture = DesignContent.template(template)
        let created = now()
        let manifest = DesignManifest(id: UUID(), name: uniqueName("Untitled design"), createdAt: created, modifiedAt: created, partCount: capture.bodies.count, template: template.rawValue)
        guard write(manifest, capture: capture) else { return nil }
        designs.append(manifest)
        return manifest
    }

    private func write(_ manifest: DesignManifest, capture: DesignCapture) -> Bool {
        let (content, blobs) = DesignContent.make(capture)
        let png = ThumbnailRenderer.render(capture.bodies.map { .init(mesh: $0.mesh, rgb: $0.style?.rgb ?? ThumbnailRenderer.defaultRGB) })?.pngData()
        do {
            try store.save(manifest, content: content, blobs: blobs, thumbnail: png)
            thumbnails.removeObject(forKey: manifest.id.uuidString as NSString)
            return true
        } catch {
            lastError = "Couldn't save the design: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func save(_ id: UUID, capture: DesignCapture) -> Bool {
        guard let index = designs.firstIndex(where: { $0.id == id }) else { return false }
        let bodies = capture.bodies.filter { !$0.mesh.positions.isEmpty }
        guard !bodies.isEmpty else { return false }
        var manifest = designs[index]
        manifest.modifiedAt = now()
        manifest.partCount = bodies.count
        guard write(manifest, capture: DesignCapture(bodies: bodies, corner: capture.corner, camera: capture.camera)) else { return false }
        designs[index] = manifest
        return true
    }

    func open(_ id: UUID) throws -> LoadedDesign {
        do { return try store.loadDesign(id) }
        catch {
            lastError = "This design couldn't be opened. Its files were kept."
            throw error
        }
    }

    private func update(_ id: UUID, _ change: (inout DesignManifest) -> Void) {
        guard let index = designs.firstIndex(where: { $0.id == id }) else { return }
        var manifest = designs[index]
        change(&manifest)
        do { try store.writeManifest(manifest); designs[index] = manifest }
        catch { lastError = "Couldn't update the design: \(error.localizedDescription)" }
    }

    func rename(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name) else { return }
        update(id) { $0.name = name }
    }

    func setFavourite(_ id: UUID, _ on: Bool) { update(id) { $0.isFavourite = on } }
    func move(_ id: UUID, toFolder folderID: UUID?) { update(id) { $0.folderID = folderID } }

    @discardableResult
    func duplicate(_ id: UUID) -> DesignManifest? {
        guard let original = designs.first(where: { $0.id == id }) else { return nil }
        let stamp = now()
        var copy = original
        copy.id = UUID()
        copy.name = uniqueName("\(original.name) copy")
        copy.createdAt = stamp
        copy.modifiedAt = stamp
        copy.isFavourite = false
        do { try store.duplicate(id, as: copy) }
        catch { lastError = "Couldn't duplicate the design: \(error.localizedDescription)"; return nil }
        designs.append(copy)
        return copy
    }

    func delete(_ id: UUID) {
        guard let manifest = designs.first(where: { $0.id == id }) else { return }
        do { try store.moveToTrash(id) }
        catch { lastError = "Couldn't delete the design: \(error.localizedDescription)"; return }
        designs.removeAll { $0.id == id }
        recentlyDeleted = manifest
    }

    func undoDelete() {
        guard let manifest = recentlyDeleted else { return }
        do { try store.restoreFromTrash(manifest.id) }
        catch { lastError = "Couldn't restore the design."; return }
        designs.append(manifest)
        recentlyDeleted = nil
    }

    func dismissDeletionNotice() { recentlyDeleted = nil }

    func removeUnreadable(_ id: UUID) {
        store.removePermanently(id)
        unreadable.removeAll { $0 == id }
    }

    func thumbnail(for id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let data = store.thumbnailData(id), let image = UIImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    // MARK: Folders

    @discardableResult
    func createFolder(_ name: String) -> DesignFolder? {
        guard let name = Self.cleaned(name) else { return nil }
        let folder = DesignFolder(id: UUID(), name: name, createdAt: now())
        folders.append(folder)
        persistLibraryFile()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name), let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        persistLibraryFile()
    }

    func deleteFolder(_ id: UUID) {
        for design in designs where design.folderID == id { move(design.id, toFolder: nil) }
        folders.removeAll { $0.id == id }
        if query.filter == .folder(id) { query.filter = .all }
        persistLibraryFile()
    }

    private func persistLibraryFile() {
        do { try store.saveLibraryFile(LibraryFile(folders: folders, sort: query.sort.rawValue)) }
        catch { lastError = "Couldn't save library settings." }
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: all `DesignLibraryTests` pass (covers Review Focus 1, 3, 4).

### Task 6: Capture, load and change hooks in the editor

**Files:**
- Modify: `FoldForm/AppModel.swift` (add convenience init), `FoldForm/RealityViewport.swift` (init, starting view, capture, change hook)
- Test: `FoldFormTests/DesignLoadTests.swift`

**Interfaces:**
- Consumes: `LoadedDesign`, `DesignCapture`, `DesignBody`.
- Produces:
  - `AppModel.init(loaded: LoadedDesign)` (convenience). Body i becomes feature `"Body i+1"`; `styles[i]` becomes that body's colour; an empty/invalid design falls back to the default plate.
  - `ViewportEntities.init(startingView: (camera: CameraRig, corner: CornerStyle)? = nil)`
  - `ViewportEntities.onContentChange: (() -> Void)?`, `func captureDesign() -> DesignCapture?`

- [ ] **Step 1: Write the failing tests** (`AppModel` half only; the viewport half is glue verified by the build)

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: `AppModel(loaded:)` not defined.

- [ ] **Step 3: Implement**

In `AppModel.swift`, after `init(document:)`:

```swift
    /// A model for a saved design: each saved body becomes a "Body n" feature, so the first is the
    /// plate and the rest are parts, exactly as the workbench builds them from any document.
    convenience init(loaded: LoadedDesign) {
        let meshes = loaded.meshes.enumerated().filter { !$0.element.positions.isEmpty }
        guard !meshes.isEmpty else { self.init(); return }
        let document = CADDocument()
        for (position, entry) in meshes.enumerated() {
            document.partStudio.featureTree.append(ViewportSolidFeature(name: "Body \(position + 1)", mesh: entry.element))
        }
        document.partStudio.regenerate()
        self.init(document: document)
        for (id, entry) in zip(document.partStudio.orderedBodyIDs, meshes) {
            if entry.offset < loaded.styles.count, let style = loaded.styles[entry.offset] { partStyles[id] = style }
        }
    }
```

In `RealityViewport.swift`, inside `ViewportEntities` (next to the other stored properties add):

```swift
    /// Called after anything that changes the saved design (every undoable edit, and undo itself).
    var onContentChange: (() -> Void)?
    private var startingView: (camera: CameraRig, corner: CornerStyle)?

    init(startingView: (camera: CameraRig, corner: CornerStyle)? = nil) {
        self.startingView = startingView
    }
```

In `setUp`, right after `frameCamera(around: initialFramingBounds(appModel: appModel))` and before `applyDebugOverrides()`:

```swift
        if let start = startingView {
            rig = start.camera
            cornerStyle = start.corner
        }
```

In `push(_:)` add `notifyContentChange()` as the last line inside the `guard` success path; in `undo()` add it after `refreshFold()`:

```swift
    private func notifyContentChange() {
        // Deferred so the edit that caused it has finished before anything captures the scene.
        DispatchQueue.main.async { [weak self] in self?.onContentChange?() }
    }

    /// The workbench as it should be saved: every part's shape with held folds baked in, its colour,
    /// the corner style and the camera. Nil before the scene has been built.
    func captureDesign() -> DesignCapture? {
        guard let appModel, let session else { return nil }
        let documentIDBySessionID = Dictionary(uniqueKeysWithValues: sessionIDByDocumentID.map { ($0.value, $0.key) })
        let bodies = session.order.compactMap { id -> DesignBody? in
            guard let mesh = session.base[id], !mesh.positions.isEmpty else { return nil }
            return DesignBody(mesh: mesh, style: documentIDBySessionID[id].flatMap { appModel.partStyles[$0] })
        }
        return DesignCapture(bodies: bodies, corner: cornerStyle, camera: rig)
    }
```

- [ ] **Step 4: Run to verify it passes** (`-only-testing:FoldFormTests/DesignLoadTests`, then the whole `FoldFormTests` suite in the background to confirm nothing else broke). Expected: 3 new tests pass, existing 174 still pass.

### Task 7: Autosave session

**Files:**
- Create: `FoldForm/Library/DesignSession.swift`
- Test: `FoldFormTests/DesignSessionTests.swift`

**Interfaces:**
- Consumes: `DesignLibrary.save(_:capture:)`, `DesignCapture`.
- Produces (`@MainActor final class DesignSession: ObservableObject`):
  - `init(designID: UUID, library: DesignLibrary, debounce: TimeInterval = 1.5)`
  - `var capture: @MainActor () -> DesignCapture?` (settable; default returns nil)
  - `func contentChanged()`, `func saveNow()`, `func close()`, `private(set) var isDirty: Bool`, `var onClosed: (() -> Void)?` (phase 2 uses this to checkpoint)

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: `DesignSession` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Saves the open design as it changes: shortly after the last change, when the app goes to the
/// background, and when the editor is closed.
@MainActor
final class DesignSession: ObservableObject {
    let designID: UUID
    private let library: DesignLibrary
    private let debounce: TimeInterval
    private var pending: Task<Void, Never>?
    private(set) var isDirty = false

    var capture: @MainActor () -> DesignCapture? = { nil }
    /// Runs once after `close()` has saved.
    var onClosed: (() -> Void)?

    init(designID: UUID, library: DesignLibrary, debounce: TimeInterval = 1.5) {
        self.designID = designID
        self.library = library
        self.debounce = debounce
    }

    func contentChanged() {
        isDirty = true
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pending?.cancel()
        pending = nil
        guard isDirty, let captured = capture() else { return }
        // A capture with no usable bodies is refused by the library, and the change stays pending.
        if library.save(designID, capture: captured) { isDirty = false }
    }

    func close() {
        saveNow()
        onClosed?()
    }
}
```

- [ ] **Step 4: Run to verify it passes.** Expected: 5 tests pass.

### Task 8: App navigation (AppRoot, EditorView, back pill)

**Files:**
- Modify: `FoldForm/FoldFormApp.swift`, `FoldFormUITests/GestureUITests.swift` (launch argument only)

**Interfaces:**
- Consumes: `DesignLibrary`, `DesignSession`, `LoadedDesign`, `ViewportEntities(startingView:)`, `AppModel(loaded:)`, `DashboardView(library:onOpen:)` (Task 9; a stub is used until then).
- Produces: `AppRoot` (route between dashboard and editor), `EditorView` (the old `RootView`), launch argument `-FoldFormOpenNewDesign` (DEBUG) that creates a flat-plate design and opens it, so UI tests still start in the editor.

- [ ] **Step 1: Write the code.** Replace the top of `FoldFormApp.swift`:

```swift
@main
struct FoldFormApp: App {
    @StateObject private var library = DesignLibrary()

    var body: some Scene {
        WindowGroup {
            AppRoot(library: library)
        }
    }
}

/// A design that is open in the editor.
private struct OpenDesign: Identifiable {
    let id: UUID
    let name: String
    let loaded: LoadedDesign
}

/// Dashboard or editor. Opening a design builds a fresh editor for it (`.id`), so nothing carries
/// over between designs.
struct AppRoot: View {
    @ObservedObject var library: DesignLibrary
    @State private var open: OpenDesign?
    @AppStorage("darkMode") private var darkMode = true

    var body: some View {
        ZStack {
            if let open {
                EditorView(library: library, designID: open.id, designName: open.name, loaded: open.loaded, onClose: { self.open = nil })
                    .id(open.id)
                    .transition(.opacity)
            } else {
                DashboardView(library: library, onOpen: openDesign)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: open?.id)
        .preferredColorScheme(darkMode ? .dark : .light)
        .alert("Couldn't open design", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.lastError ?? "") }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-FoldFormOpenNewDesign"), open == nil,
               let design = library.createDesign(template: .sheetPlate) {
                openDesign(design.id)
            }
            #endif
        }
    }

    private func openDesign(_ id: UUID) {
        guard let manifest = library.designs.first(where: { $0.id == id }),
              let loaded = try? library.open(id) else { return }
        open = OpenDesign(id: id, name: manifest.name, loaded: loaded)
    }
}
```

Rename `RootView` to `EditorView` and change its stored properties and init:

```swift
struct EditorView: View {
    @ObservedObject var library: DesignLibrary
    let designID: UUID
    let designName: String
    let onClose: () -> Void
    @StateObject private var appModel: AppModel
    @StateObject private var viewport: ViewportEntities
    @StateObject private var session: DesignSession
    @Environment(\.scenePhase) private var scenePhase
    // ... existing @State / @AppStorage properties unchanged (showTools, darkMode, showDimensions, dimensionUnit, moveMode, exportFile)

    init(library: DesignLibrary, designID: UUID, designName: String, loaded: LoadedDesign, onClose: @escaping () -> Void) {
        self.library = library
        self.designID = designID
        self.designName = designName
        self.onClose = onClose
        _appModel = StateObject(wrappedValue: AppModel(loaded: loaded))
        _viewport = StateObject(wrappedValue: ViewportEntities(startingView: loaded.camera.map { ($0, loaded.corner) }))
        _session = StateObject(wrappedValue: DesignSession(designID: designID, library: library))
    }
```

Remove the old `@StateObject private var appModel = AppModel()` and `@StateObject private var viewport = ViewportEntities()` lines. Note `loaded.camera.map { ($0, loaded.corner) }` gives nil when there is no saved camera; then also handle corner-only by passing `(camera: rig, corner:)` only when a camera exists (a design always saves its camera once opened, and a fresh template starts fillet, so this is fine).

In `body`, wire the session and the back pill, replacing `.overlay(alignment: .top) { touchUpBanner }`:

```swift
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    designPill
                    touchUpBanner
                }
            }
        .onAppear {
            viewport.referenceVisibility.darkMode = darkMode
            session.capture = { [weak viewport] in viewport?.captureDesign() }
            viewport.onContentChange = { [weak session] in session?.contentChanged() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
```

(Delete the previous `.onAppear { viewport.referenceVisibility.darkMode = darkMode }` line, since it is merged above.) Add the pill:

```swift
    /// Back to the dashboard: saves first, then shows the design's name.
    private var designPill: some View {
        Button {
            session.close()
            onClose()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                Text(library.designs.first { $0.id == designID }?.name ?? designName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.top, 16)
        .accessibilityIdentifier("designsButton")
        .accessibilityLabel("Back to designs")
    }
```

Remove `.preferredColorScheme(darkMode ? .dark : .light)` from `EditorView` (now applied by `AppRoot`). In `GestureUITests.swift`, add `app.launchArguments += ["-FoldFormOpenNewDesign"]` wherever the app is launched (do not run them).

- [ ] **Step 2: Build** (`xcodegen generate` first, then `xcodebuild ... build`, in the background). Expected: build succeeds once Task 9's `DashboardView` exists; until then add a temporary `DashboardView` stub in Task 9's file location so this task compiles on its own:

```swift
struct DashboardView: View {
    @ObservedObject var library: DesignLibrary
    var onOpen: (UUID) -> Void
    var body: some View { Text("Designs") }
}
```

(Task 9 replaces this file's contents.)

- [ ] **Step 3: Run the whole unit suite in the background.** Expected: all pass (no test references `RootView`; if one does, rename it).

### Task 9: Dashboard UI

**Files:**
- Create/replace: `FoldForm/Dashboard/DashboardView.swift`, `DesignCard.swift`, `StatsHeader.swift`, `FolderBar.swift`, `TemplatePicker.swift`

**Interfaces:**
- Consumes: everything on `DesignLibrary`.
- Produces: `DashboardView(library:onOpen:)`; later phases add menu items to `DesignCard`'s context menu via closures `onHistory` and `onShare` (added in Tasks 11 and 12).

- [ ] **Step 1: `StatsHeader.swift`**

```swift
import SwiftUI

struct StatsHeader: View {
    let stats: DashboardStats

    var body: some View {
        HStack(spacing: 10) {
            tile("Designs", stats.designs, "square.stack.3d.up.fill", .blue)
            tile("Parts", stats.parts, "cube.fill", .indigo)
            tile("Favourites", stats.favourites, "star.fill", .orange)
            tile("This week", stats.editedThisWeek, "clock.fill", .green)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statsHeader")
    }

    private func tile(_ title: String, _ value: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text("\(value)").font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
```

- [ ] **Step 2: `FolderBar.swift`**

```swift
import SwiftUI

struct FolderBar: View {
    @ObservedObject var library: DesignLibrary
    var showsShared = false
    var onNewFolder: () -> Void
    @State private var renaming: DesignFolder?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", "square.grid.2x2", .all)
                chip("Favourites", "star", .favourites)
                if showsShared { chip("Shared", "person.2", .shared) }
                ForEach(library.folders) { folder in
                    chip(folder.name, "folder", .folder(folder.id))
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renameText = folder.name; renaming = folder }
                            Button("Delete folder", systemImage: "trash", role: .destructive) { library.deleteFolder(folder.id) }
                        }
                }
                Button(action: onNewFolder) {
                    Label("Folder", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newFolderButton")
            }
        }
        .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let renaming { library.renameFolder(renaming.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(_ title: String, _ symbol: String, _ filter: DesignFilter) -> some View {
        let selected = library.query.filter == filter
        return Button { library.query.filter = filter } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
```

- [ ] **Step 3: `DesignCard.swift`**

```swift
import SwiftUI

struct DesignCard: View {
    let design: DesignManifest
    let image: UIImage?
    let folderName: String?
    var isShared = false
    var onToggleFavourite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(.tertiarySystemGroupedBackground), Color.accentColor.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(12)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 34)).foregroundStyle(.secondary)
                }
                Button(action: onToggleFavourite) {
                    Image(systemName: design.isFavourite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(design.isFavourite ? Color.orange : Color.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel(design.isFavourite ? "Remove from favourites" : "Add to favourites")
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 3) {
                Text(design.name)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(design.modifiedAt, style: .relative)
                    Text("·")
                    Text("\(design.partCount) part\(design.partCount == 1 ? "" : "s")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if folderName != nil || isShared {
                    HStack(spacing: 8) {
                        if let folderName { Label(folderName, systemImage: "folder.fill") }
                        if isShared { Label("Shared", systemImage: "person.2.fill") }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("designCard-\(design.name)")
    }
}
```

- [ ] **Step 4: `TemplatePicker.swift`**

```swift
import SwiftUI

/// Choosing what a new design starts from.
struct TemplatePicker: View {
    var onPick: (PartProfileKind) -> Void
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(PartProfileKind.allCases) { kind in
                        Button {
                            dismiss()
                            onPick(kind)
                        } label: {
                            VStack(spacing: 8) {
                                preview(for: kind)
                                    .frame(height: 96)
                                Text(kind.rawValue).font(.system(.subheadline, design: .rounded, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("template-\(kind.rawValue)")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New design")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func preview(for kind: PartProfileKind) -> some View {
        if let image = TemplatePreviews.image(for: kind) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum TemplatePreviews {
    private static var cache: [PartProfileKind: UIImage] = [:]

    static func image(for kind: PartProfileKind) -> UIImage? {
        if let cached = cache[kind] { return cached }
        let capture = DesignContent.template(kind)
        let image = ThumbnailRenderer.render(capture.bodies.map { .init(mesh: $0.mesh, rgb: ThumbnailRenderer.defaultRGB) },
                                             size: CGSize(width: 240, height: 180))
        if let image { cache[kind] = image }
        return image
    }
}
```

- [ ] **Step 5: `DashboardView.swift`** (replaces the Task 8 stub)

```swift
import SwiftUI

struct DashboardView: View {
    @ObservedObject var library: DesignLibrary
    var onOpen: (UUID) -> Void

    @State private var showTemplates = false
    @State private var renaming: DesignManifest?
    @State private var renameText = ""
    @State private var deleting: DesignManifest?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var toastDismiss: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatsHeader(stats: library.stats)
                    FolderBar(library: library, onNewFolder: { newFolderName = ""; showNewFolder = true })
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Designs")
            .searchable(text: $library.query.text, prompt: "Search designs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTemplates = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityIdentifier("newDesignButton")
                        .accessibilityLabel("New design")
                }
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { kind in
                if let design = library.createDesign(template: kind) { onOpen(design.id) }
            }
        }
        .alert("Rename design", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let renaming { library.rename(renaming.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { if let folder = library.createFolder(newFolderName) { library.query.filter = .folder(folder.id) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { library.delete(deleting.id); scheduleToastDismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can undo this for a few seconds.") }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: library.recentlyDeleted?.id)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let visible = library.visibleDesigns
        if library.designs.isEmpty && library.unreadable.isEmpty {
            emptyState
        } else if visible.isEmpty && library.unreadable.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text("No designs match").font(.headline)
                Text("Try a different search or filter.").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(visible) { design in
                    DesignCard(
                        design: design,
                        image: library.thumbnail(for: design.id),
                        folderName: library.folderName(design.folderID),
                        isShared: library.sharedIDs.contains(design.id),
                        onToggleFavourite: { library.setFavourite(design.id, !design.isFavourite) }
                    )
                    .onTapGesture { onOpen(design.id) }
                    .contextMenu { menu(for: design) }
                }
                ForEach(library.unreadable, id: \.self) { id in unreadableCard(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent").font(.system(size: 54)).foregroundStyle(Color.accentColor)
            Text("No designs yet").font(.system(.title2, design: .rounded, weight: .bold))
            Text("Start a design and it will be saved here automatically.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showTemplates = true } label: {
                Label("Start your first design", systemImage: "plus")
                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
            }
            .accessibilityIdentifier("startFirstDesignButton")
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }

    private func unreadableCard(_ id: UUID) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
            Text("Couldn't open").font(.subheadline.weight(.semibold))
            Button("Delete", role: .destructive) { library.removeUnreadable(id) }.font(.footnote)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder private func menu(for design: DesignManifest) -> some View {
        Button("Open", systemImage: "arrow.up.right.square") { onOpen(design.id) }
        Button("Rename", systemImage: "pencil") { renameText = design.name; renaming = design }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(design.id) }
        Button(design.isFavourite ? "Remove favourite" : "Favourite", systemImage: design.isFavourite ? "star.slash" : "star") {
            library.setFavourite(design.id, !design.isFavourite)
        }
        Menu("Move to folder", systemImage: "folder") {
            Button("No folder") { library.move(design.id, toFolder: nil) }
            ForEach(library.folders) { folder in Button(folder.name) { library.move(design.id, toFolder: folder.id) } }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = design }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { library.query.sort }, set: { library.setSort($0) })) {
                ForEach(DesignSort.allCases) { Text($0.title).tag($0) }
            }
        } label: { Image(systemName: "arrow.up.arrow.down.circle") }
        .accessibilityIdentifier("sortMenu")
        .accessibilityLabel("Sort")
    }

    // MARK: Delete toast

    @ViewBuilder private var toast: some View {
        if let deleted = library.recentlyDeleted {
            HStack(spacing: 14) {
                Text("Deleted \"\(deleted.name)\"").font(.subheadline).lineLimit(1)
                Button("Undo") { library.undoDelete() }.font(.subheadline.weight(.bold))
                    .accessibilityIdentifier("undoDeleteButton")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func scheduleToastDismiss() {
        toastDismiss?.cancel()
        toastDismiss = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            library.dismissDeletionNotice()
        }
    }
}
```

- [ ] **Step 6: Build and run the unit suite in the background.** Expected: build succeeds; all tests pass. No simulator UI is driven.

- [ ] **Step 7: Relaunch normally.** If a simulator is already booted, build, install and launch the app the normal way so the user finds the dashboard (never leave UI-test state on it).

---

# Phase 2: Version history

### Task 10: Version store, library operations and UI

**Files:**
- Modify: `FoldForm/Library/DesignStore.swift` (version files), `FoldForm/Library/DesignLibrary.swift` (version operations), `FoldForm/FoldFormApp.swift` (checkpoint on close, restore reopen), `FoldForm/Dashboard/DashboardView.swift` (menu item + sheet)
- Create: `FoldForm/Dashboard/VersionHistoryView.swift`
- Test: `FoldFormTests/VersionTests.swift`

**Interfaces:**
- Produces: `struct DesignVersion: Codable, Identifiable, Equatable { id: UUID; name: String; note: String; createdAt: Date; isAutomatic: Bool; partCount: Int; content: DesignContent }`.
  - Store: `func saveVersion(_ v: DesignVersion, designID: UUID, thumbnail: Data?) throws`, `func listVersions(_ designID: UUID) -> [DesignVersion]` (newest first), `func deleteVersion(_ id: UUID, designID: UUID)`, `func versionThumbnailData(_ id: UUID, designID: UUID) -> Data?`.
  - Library: `func versions(of id: UUID) -> [DesignVersion]`, `@discardableResult func saveVersion(of id: UUID, name: String?, note: String, automatic: Bool) -> DesignVersion?`, `func checkpointIfChanged(_ id: UUID)`, `func restoreVersion(_ versionID: UUID, of id: UUID) throws -> LoadedDesign`, `func deleteVersion(_ versionID: UUID, of id: UUID)`, `static let maxAutomaticVersions = 20`, `func versionThumbnail(_ versionID: UUID, of id: UUID) -> UIImage?`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: `saveVersion` etc. not defined.

- [ ] **Step 3: Implement.**

Add to `DesignModels.swift`:

```swift
struct DesignVersion: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var note: String
    var createdAt: Date
    var isAutomatic: Bool
    var partCount: Int
    var content: DesignContent
}
```

Add to `DesignStore`:

```swift
    // MARK: Versions

    private func versionFolder(_ id: UUID, designID: UUID) -> URL {
        versionsURL(designID).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func saveVersion(_ version: DesignVersion, designID: UUID, thumbnail: Data?) throws {
        let folder = versionFolder(version.id, designID: designID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let thumbnail { try thumbnail.write(to: folder.appendingPathComponent("thumbnail.png"), options: .atomic) }
        try encode(version).write(to: folder.appendingPathComponent("version.json"), options: .atomic)
    }

    func listVersions(_ designID: UUID) -> [DesignVersion] {
        let folders = (try? fm.contentsOfDirectory(at: versionsURL(designID), includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? decode(DesignVersion.self, from: $0.appendingPathComponent("version.json")) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    func deleteVersion(_ id: UUID, designID: UUID) {
        try? fm.removeItem(at: versionFolder(id, designID: designID))
        collectGarbage(for: designID)
    }

    func versionThumbnailData(_ id: UUID, designID: UUID) -> Data? {
        try? Data(contentsOf: versionFolder(id, designID: designID).appendingPathComponent("thumbnail.png"))
    }
```

Add to `DesignLibrary`:

```swift
    // MARK: Versions

    static let maxAutomaticVersions = 20

    func versions(of id: UUID) -> [DesignVersion] { store.listVersions(id) }

    @discardableResult
    func saveVersion(of id: UUID, name: String?, note: String, automatic: Bool) -> DesignVersion? {
        guard let manifest = designs.first(where: { $0.id == id }), let content = try? store.loadContent(id) else { return nil }
        let existing = store.listVersions(id)
        let title = Self.cleaned(name ?? "") ?? (automatic ? "Checkpoint" : "Version \(existing.filter { !$0.isAutomatic }.count + 1)")
        let version = DesignVersion(id: UUID(), name: title, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    createdAt: now(), isAutomatic: automatic, partCount: manifest.partCount, content: content)
        do { try store.saveVersion(version, designID: id, thumbnail: store.thumbnailData(id)) }
        catch { lastError = "Couldn't save the version: \(error.localizedDescription)"; return nil }
        pruneAutomaticVersions(of: id)
        return version
    }

    /// Records an automatic version if the design differs from its newest version.
    func checkpointIfChanged(_ id: UUID) {
        guard let content = try? store.loadContent(id) else { return }
        if store.listVersions(id).first?.content == content { return }
        saveVersion(of: id, name: nil, note: "", automatic: true)
    }

    private func pruneAutomaticVersions(of id: UUID) {
        let automatic = store.listVersions(id).filter(\.isAutomatic)   // newest first
        for stale in automatic.dropFirst(Self.maxAutomaticVersions) { store.deleteVersion(stale.id, designID: id) }
    }

    /// Makes a version the current state of the design. The state being replaced is kept as an
    /// automatic version first (unless an identical one already exists), so a restore can be undone.
    func restoreVersion(_ versionID: UUID, of id: UUID) throws -> LoadedDesign {
        guard let version = store.listVersions(id).first(where: { $0.id == versionID }),
              let index = designs.firstIndex(where: { $0.id == id }) else { throw DesignStoreError.notFound }
        let loaded = version.content.loaded(meshes: try store.loadMeshes(version.content, for: id))
        if let current = try? store.loadContent(id), !store.listVersions(id).contains(where: { $0.content == current }) {
            saveVersion(of: id, name: "Before restore", note: "", automatic: true)
        }
        try store.replaceContent(version.content, for: id)
        if let thumbnail = store.versionThumbnailData(versionID, designID: id) { try? store.writeThumbnail(thumbnail, for: id) }
        var manifest = designs[index]
        manifest.modifiedAt = now()
        manifest.partCount = version.partCount
        try store.writeManifest(manifest)
        designs[index] = manifest
        thumbnails.removeObject(forKey: id.uuidString as NSString)
        return loaded
    }

    func deleteVersion(_ versionID: UUID, of id: UUID) { store.deleteVersion(versionID, designID: id) }

    func versionThumbnail(_ versionID: UUID, of id: UUID) -> UIImage? {
        store.versionThumbnailData(versionID, designID: id).flatMap(UIImage.init(data:))
    }
```

Restoring keeps `Before restore` as an automatic version, which the prune rule may later delete; that is the intended limit.

In `AppRoot`, wire the checkpoint (inside `EditorView.init` after creating the session is not possible before the StateObject exists, so do it in `designPill`'s action and the same place scene changes use):

```swift
        Button {
            session.close()
            library.checkpointIfChanged(designID)
            onClose()
        }
```

(Use this in place of the `onClosed` closure in the app; `onClosed` stays for tests and future use.)

- [ ] **Step 4: `VersionHistoryView.swift`**

```swift
import SwiftUI

struct VersionHistoryView: View {
    @ObservedObject var library: DesignLibrary
    let design: DesignManifest
    /// Called after a restore with the design's new contents, so the app can open it.
    var onRestored: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [DesignVersion] = []
    @State private var showSave = false
    @State private var name = ""
    @State private var note = ""
    @State private var confirming: DesignVersion?

    var body: some View {
        NavigationStack {
            Group {
                if versions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("No versions yet").font(.headline)
                        Text("Save a version to keep a copy you can come back to. A checkpoint is also saved when you close a design you changed.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                } else {
                    List {
                        ForEach(versions) { version in
                            row(version)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { library.deleteVersion(version.id, of: design.id); reload() }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save version") { name = ""; note = ""; showSave = true }.accessibilityIdentifier("saveVersionButton")
                }
            }
            .alert("Save version", isPresented: $showSave) {
                TextField("Name", text: $name)
                TextField("Note (optional)", text: $note)
                Button("Save") { library.saveVersion(of: design.id, name: name, note: note, automatic: false); reload() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Restore \"\(confirming?.name ?? "")\"?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                Button("Restore") {
                    if let confirming, (try? library.restoreVersion(confirming.id, of: design.id)) != nil {
                        dismiss()
                        onRestored(design.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your current design is saved as a version first, so you can go back.") }
        }
        .onAppear(perform: reload)
    }

    private func reload() { versions = library.versions(of: design.id) }

    private func row(_ version: DesignVersion) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = library.versionThumbnail(version.id, of: design.id) { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "cube.transparent").foregroundStyle(.secondary) }
            }
            .frame(width: 64, height: 48)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.name).font(.subheadline.weight(.semibold))
                    if version.isAutomatic { Text("Auto").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.2), in: Capsule()) }
                }
                Text(version.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text("\(version.partCount) part\(version.partCount == 1 ? "" : "s")" + (version.note.isEmpty ? "" : " · \(version.note)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Restore") { confirming = version }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}
```

In `DashboardView` add `@State private var historyFor: DesignManifest?`, a menu item `Button("Version history", systemImage: "clock.arrow.circlepath") { historyFor = design }`, and

```swift
        .sheet(item: $historyFor) { design in
            VersionHistoryView(library: library, design: design, onRestored: onOpen)
        }
```

(`DesignManifest` is `Identifiable`.) `onRestored` reuses `onOpen`, which reopens the restored design.

- [ ] **Step 5: Run to verify it passes** (`-only-testing:FoldFormTests/VersionTests`, then the full suite in the background). Expected: 7 new tests pass.

---

# Phase 3: Collaboration preview (no backend)

### Task 11: Collaboration service, sharing UI and presence

**Files:**
- Create: `FoldForm/Library/CollaborationService.swift`, `FoldForm/Dashboard/ShareView.swift`
- Modify: `FoldForm/Library/DesignLibrary.swift` (service dependency, `sharedIDs`), `FoldForm/Dashboard/DashboardView.swift` (Share menu item, Shared chip), `FoldForm/FoldFormApp.swift` (presence strip)
- Test: `FoldFormTests/CollaborationTests.swift`

**Interfaces:**
- Produces:
  - `enum CollaboratorRole: String, Codable, CaseIterable, Identifiable { case viewer, editor; var title: String }`
  - `struct Collaborator: Identifiable, Codable, Equatable { id: UUID; name: String; email: String; role: CollaboratorRole; invitedAt: Date }`
  - `struct ActivityItem: Identifiable, Equatable { id: UUID; who: String; text: String; at: Date; isSample: Bool }`
  - `enum CollaborationError: Error, Equatable, LocalizedError { case invalidEmail, alreadyInvited }`
  - `protocol CollaborationService: AnyObject { var isConnected: Bool { get }; func collaborators(for design: UUID) -> [Collaborator]; func invite(email: String, role: CollaboratorRole, to design: UUID) throws -> Collaborator; func remove(_ collaborator: UUID, from design: UUID); func setRole(_ role: CollaboratorRole, for collaborator: UUID, in design: UUID); func sharedDesignIDs() -> Set<UUID>; func activity(for design: UUID) -> [ActivityItem] }`
  - `final class LocalPreviewCollaborationService: CollaborationService` with `init(fileURL: URL, now: @escaping () -> Date = Date.init)`; `isConnected` is always `false`.
  - `DesignLibrary.init(store:collaboration:now:)` (new defaulted parameter), `var collaboration: CollaborationService`, `func refreshShared()` which sets `sharedIDs`.
  - `static let previewBanner = "Preview: not connected to a server"`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify it fails.** Expected: types not defined.

- [ ] **Step 3: Implement `CollaborationService.swift`**

```swift
import Foundation

enum CollaboratorRole: String, Codable, CaseIterable, Identifiable {
    case viewer, editor
    var id: String { rawValue }
    var title: String { self == .viewer ? "Can view" : "Can edit" }
}

struct Collaborator: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var email: String
    var role: CollaboratorRole
    var invitedAt: Date
}

struct ActivityItem: Identifiable, Equatable {
    var id: UUID
    var who: String
    var text: String
    var at: Date
    var isSample: Bool
}

enum CollaborationError: Error, Equatable, LocalizedError {
    case invalidEmail, alreadyInvited
    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .alreadyInvited: return "That person is already on this design."
        }
    }
}

/// Sharing and live co-editing. Nothing implements this against a server yet; the only
/// implementation below keeps a local list and sends nothing anywhere.
protocol CollaborationService: AnyObject {
    var isConnected: Bool { get }
    func collaborators(for design: UUID) -> [Collaborator]
    func invite(email: String, role: CollaboratorRole, to design: UUID) throws -> Collaborator
    func remove(_ collaborator: UUID, from design: UUID)
    func setRole(_ role: CollaboratorRole, for collaborator: UUID, in design: UUID)
    func sharedDesignIDs() -> Set<UUID>
    func activity(for design: UUID) -> [ActivityItem]
}

/// Stores invitations in a local file so the sharing screens can be designed and tried. It never
/// contacts anyone: an "invitation" is only a row in that file.
final class LocalPreviewCollaborationService: CollaborationService {
    static let previewBanner = "Preview: not connected to a server"

    private let fileURL: URL
    private let now: () -> Date
    private var byDesign: [UUID: [Collaborator]]

    var isConnected: Bool { false }

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        let stored = (try? JSONDecoder().decode([String: [Collaborator]].self, from: Data(contentsOf: fileURL))) ?? [:]
        byDesign = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: byDesign.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func normalised(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !value.contains(where: \.isWhitespace),
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return value
    }

    func collaborators(for design: UUID) -> [Collaborator] { byDesign[design] ?? [] }

    func invite(email: String, role: CollaboratorRole, to design: UUID) throws -> Collaborator {
        guard let address = Self.normalised(email) else { throw CollaborationError.invalidEmail }
        guard !collaborators(for: design).contains(where: { $0.email == address }) else { throw CollaborationError.alreadyInvited }
        let name = String(address.split(separator: "@")[0]).capitalized
        let person = Collaborator(id: UUID(), name: name, email: address, role: role, invitedAt: now())
        byDesign[design, default: []].append(person)
        persist()
        return person
    }

    func remove(_ collaborator: UUID, from design: UUID) {
        byDesign[design]?.removeAll { $0.id == collaborator }
        if byDesign[design]?.isEmpty == true { byDesign[design] = nil }
        persist()
    }

    func setRole(_ role: CollaboratorRole, for collaborator: UUID, in design: UUID) {
        guard let index = byDesign[design]?.firstIndex(where: { $0.id == collaborator }) else { return }
        byDesign[design]?[index].role = role
        persist()
    }

    func sharedDesignIDs() -> Set<UUID> { Set(byDesign.filter { !$0.value.isEmpty }.keys) }

    /// Made-up entries for the people invited, so the feed can be designed. Every one is marked sample.
    func activity(for design: UUID) -> [ActivityItem] {
        collaborators(for: design).flatMap { person -> [ActivityItem] in
            let texts = person.role == .editor ? ["joined the design", "edited a part"] : ["joined the design", "viewed the design"]
            return texts.enumerated().map { offset, text in
                ActivityItem(id: UUID(), who: person.name, text: text, at: person.invitedAt.addingTimeInterval(Double(offset) * 600), isSample: true)
            }
        }
        .sorted { $0.at > $1.at }
    }
}
```

`LocalPreviewCollaborationService.previewBanner` is the text every collaboration screen shows.

In `DesignLibrary`: add `var collaboration: CollaborationService` as a stored `let`, change the init signature to `init(store: DesignStore = DesignStore(), collaboration: CollaborationService? = nil, now: @escaping () -> Date = Date.init)`, set `self.collaboration = collaboration ?? LocalPreviewCollaborationService(fileURL: store.root.appendingPathComponent("collab-preview.json"))` before `store.emptyTrash()`, add `func refreshShared() { sharedIDs = collaboration.sharedDesignIDs() }` and call `refreshShared()` at the end of `init`. Change the `sharedIDs` declaration to `@Published private(set) var sharedIDs: Set<UUID> = []`.

- [ ] **Step 4: `ShareView.swift`**

```swift
import SwiftUI

struct PreviewBanner: View {
    var body: some View {
        Label(LocalPreviewCollaborationService.previewBanner, systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("previewBanner")
    }
}

struct ShareView: View {
    @ObservedObject var library: DesignLibrary
    let design: DesignManifest
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role: CollaboratorRole = .editor
    @State private var people: [Collaborator] = []
    @State private var activity: [ActivityItem] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section { PreviewBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("People") {
                    personRow(name: "You", detail: "Owner", tint: .accentColor, sample: false)
                    ForEach(people) { person in
                        HStack {
                            avatar(person.name, tint: .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).font(.subheadline.weight(.semibold))
                                Text(person.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu(person.role.title) {
                                ForEach(CollaboratorRole.allCases) { r in
                                    Button(r.title) { library.collaboration.setRole(r, for: person.id, in: design.id); reload() }
                                }
                                Button("Remove", role: .destructive) { library.collaboration.remove(person.id, from: design.id); reload() }
                            }
                            .font(.footnote)
                        }
                    }
                }
                Section("Invite (stored on this device only)") {
                    TextField("Email address", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                        .accessibilityIdentifier("inviteEmailField")
                    Picker("Access", selection: $role) { ForEach(CollaboratorRole.allCases) { Text($0.title).tag($0) } }
                    Button("Add person") { invite() }.accessibilityIdentifier("inviteButton")
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    Text("Nothing is sent. When a server is connected, people added here will be invited for real.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !activity.isEmpty {
                    Section("Activity") {
                        ForEach(activity) { item in
                            HStack(spacing: 10) {
                                avatar(item.who, tint: .purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.who) \(item.text)").font(.subheadline)
                                    Text(item.at, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Sample").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Share \"\(design.name)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear(perform: reload)
    }

    private func invite() {
        do {
            _ = try library.collaboration.invite(email: email, role: role, to: design.id)
            email = ""; error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        people = library.collaboration.collaborators(for: design.id)
        activity = library.collaboration.activity(for: design.id)
        library.refreshShared()
    }

    private func personRow(name: String, detail: String, tint: Color, sample: Bool) -> some View {
        HStack {
            avatar(name, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func avatar(_ name: String, tint: Color) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: Circle())
    }
}
```

In `DashboardView` add `@State private var sharingFor: DesignManifest?`, the menu item `Button("Share", systemImage: "person.badge.plus") { sharingFor = design }`, the sheet `.sheet(item: $sharingFor) { ShareView(library: library, design: $0) }`, and pass `showsShared: true` to `FolderBar`. In the `AppRoot`/`EditorView`, add a presence strip: under `designPill`, when `library.collaboration.collaborators(for: designID)` is non-empty, show avatars with a dashed outline plus the text "Preview", inside the same top `VStack`:

```swift
    @ViewBuilder private var presenceStrip: some View {
        let people = library.collaboration.collaborators(for: designID)
        if !people.isEmpty {
            HStack(spacing: -6) {
                ForEach(people.prefix(4)) { person in
                    Text(String(person.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                Text("Preview").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10)
            }
            .allowsHitTesting(false)
        }
    }
```

- [ ] **Step 5: Verify nothing can touch the network**, then run the tests.

Run: `grep -rn "URLSession\|NWConnection\|URLRequest\|CFStream\|WebSocket" FoldForm/Library FoldForm/Dashboard`
Expected: no output.

Run `-only-testing:FoldFormTests/CollaborationTests` in the background. Expected: 7 tests pass (covers Review Focus 5).

---

### Task 12: Documentation, full verification and notes

**Files:**
- Modify: `docs/features.md`, `docs/controls.md`, `docs/architecture.md`, `docs/README.md`
- Create: `/Users/murthy/.claude/projects/-Users-murthy-Documents-FoldForm/memory/project_dashboard.md` and one line in `MEMORY.md`

- [ ] **Step 1: Docs.** In `docs/features.md` add "Dashboard and saved designs", "Version history" and "Collaboration preview (no server)" sections. In `docs/controls.md` add the dashboard controls (new, search, sort, chips, long-press menu, delete Undo toast) and the editor's back pill. In `docs/architecture.md` add the storage layout, the capture/load path, autosave and the `CollaborationService` protocol as the backend plug point, and state that undo history is not saved. In `docs/README.md` change the quick start to start from the dashboard.
- [ ] **Step 2: Regenerate and build.** `xcodegen generate`, then build in the background. Expected: build succeeds with no new warnings about concurrency.
- [ ] **Step 3: Full unit suite** (background, poll the log). Expected: the previous 174 tests plus about 60 new ones all pass.
- [ ] **Step 4: Scan.** `grep -rn "TODO\|FIXME" FoldForm/Library FoldForm/Dashboard` (expect none) and the networking grep from Task 11.
- [ ] **Step 5: Memory.** Write `project_dashboard.md` (dashboard built in three phases, storage layout, decisions: no undo persistence, collaboration is a labelled UI preview with no backend, deviations from the spec) and add its pointer to `MEMORY.md`.
- [ ] **Step 6: Report** what was built, what was verified (unit tests, build) and what was not (the live UI was not driven, per the standing rule; the user should launch it and look at the dashboard), and remind that nothing was committed.
