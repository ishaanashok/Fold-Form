import Foundation
import CryptoKit

enum ModelStoreError: Error, Equatable {
    case insecureURL
    case http(Int)
    case hashMismatch(String)
    case invalidManifest
}

/// Downloads model files on first use and keeps them on disk. A model is installed all-or-nothing: files
/// are fetched into a staging folder, each is hashed as it arrives, and only when every hash matches is
/// the folder moved into place.
final class ModelStore: Sendable {
    private let root: URL
    private let session: URLSession

    init(root: URL = ModelStore.defaultRoot, session: URLSession = .shared) {
        self.root = root
        self.session = session
    }

    static var defaultRoot: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FoldForm", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func directory(for manifest: ModelManifest) -> URL {
        root.appendingPathComponent(manifest.id, isDirectory: true)
    }

    func isInstalled(_ manifest: ModelManifest) -> Bool {
        guard !manifest.files.isEmpty else { return false }
        let directory = directory(for: manifest)
        return manifest.files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path) }
    }

    func remove(_ manifest: ModelManifest) {
        try? FileManager.default.removeItem(at: directory(for: manifest))
    }

    /// Installs the model unless it is already on disk. `progress` receives a rising fraction from 0 to 1.
    func install(_ manifest: ModelManifest, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !manifest.files.isEmpty, manifest.files.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("/") }) else {
            throw ModelStoreError.invalidManifest
        }
        guard manifest.files.allSatisfy({ $0.url.scheme?.lowercased() == "https" }) else { throw ModelStoreError.insecureURL }
        if isInstalled(manifest) {
            progress?(1)
            return
        }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let count = Double(manifest.files.count)
        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            try await download(file, into: staging) { fraction in
                progress?((Double(index) + fraction) / count)
            }
        }
        let destination = directory(for: manifest)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        progress?(1)
    }

    private func download(_ file: ModelManifest.File, into directory: URL, progress: @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await session.bytes(from: file.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.http(http.statusCode)
        }
        let expected = response.expectedContentLength
        let target = directory.appendingPathComponent(file.name)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunk = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if expected > 0 { progress(min(1, Double(received) / Double(expected))) }
            }
        }
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else { throw ModelStoreError.hashMismatch(file.name) }
    }
}
