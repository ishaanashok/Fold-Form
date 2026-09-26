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

    // MARK: Library file

    func loadLibraryFile() -> LibraryFile {
        (try? decode(LibraryFile.self, from: libraryFileURL)) ?? LibraryFile()
    }

    func saveLibraryFile(_ file: LibraryFile) throws {
        try encode(file).write(to: libraryFileURL, options: .atomic)
    }
}
