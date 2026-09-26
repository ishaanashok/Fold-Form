import Foundation

/// A model made of one or more files, each pinned to a SHA-256 so a swapped or truncated download is
/// caught before it is ever loaded.
struct ModelManifest: Sendable, Equatable {
    struct File: Sendable, Equatable {
        let name: String
        let url: URL
        /// Lowercase hex SHA-256 of the file's bytes.
        let sha256: String
    }
    let id: String
    let files: [File]
}
