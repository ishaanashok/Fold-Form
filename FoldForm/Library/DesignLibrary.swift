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
    let collaboration: CollaborationService
    private let now: () -> Date
    private let thumbnails = NSCache<NSString, UIImage>()

    init(store: DesignStore = DesignStore(), collaboration: CollaborationService? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.collaboration = collaboration ?? LocalPreviewCollaborationService(fileURL: store.root.appendingPathComponent("collab-preview.json"))
        self.now = now
        store.emptyTrash()
        reload()
        let file = store.loadLibraryFile()
        folders = file.folders
        query.sort = DesignSort(rawValue: file.sort) ?? .lastEdited
        refreshShared()
    }

    private func reload() {
        let listing = store.listManifests()
        designs = listing.manifests
        unreadable = listing.unreadable
    }

    // MARK: Query

    var visibleDesigns: [DesignManifest] { Self.visible(designs, query: query, sharedIDs: sharedIDs) }

    /// Designs shared with someone, according to the collaboration service.
    @Published private(set) var sharedIDs: Set<UUID> = []

    func refreshShared() { sharedIDs = collaboration.sharedDesignIDs() }

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
