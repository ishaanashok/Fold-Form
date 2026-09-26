import Foundation

enum NeedleRuntimeError: Error, Equatable {
    case notLoaded
    case loadFailed(String)
    case initFailed(String)
    case completeFailed(String)
}

/// Needle 3 through Cactus's C engine. The engine holds one process-wide model and is not thread-safe, so
/// every call goes through one serial queue.
final class CactusNeedleRuntime: NeedleRuntime, @unchecked Sendable {
    static let shared = CactusNeedleRuntime()

    private let queue = DispatchQueue(label: "foldform.needle")
    private let lock = NSLock()
    private var loaded = false
    private var mapping: (pointer: UnsafeMutableRawPointer, length: Int)?
    private var declaredTools: String?
    private var loading: Task<Void, Never>?

    var isLoaded: Bool { lock.withLock { loaded } }

    /// Maps the weights file into memory. The engine reads it in place, so the mapping lives as long as the model.
    func load(from url: URL) async throws {
        try await onQueue { [self] in
            guard !isLoaded else { return }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw NeedleRuntimeError.loadFailed("can't open the model file") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0 else { throw NeedleRuntimeError.loadFailed("the model file is empty") }
            let length = Int(info.st_size)
            guard let pointer = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), pointer != MAP_FAILED else {
                throw NeedleRuntimeError.loadFailed("can't read the model file")
            }
            let status = needle_load(pointer.assumingMemoryBound(to: UInt8.self), UInt64(length))
            guard status >= 0 else {
                munmap(pointer, length)
                throw NeedleRuntimeError.loadFailed(lastError())
            }
            mapping = (pointer, length)
            lock.withLock { loaded = true }
        }
    }

    /// Downloads the weights on first use, then loads them. Safe to call repeatedly.
    func prepare(store: ModelStore = ModelStore(), manifest: ModelManifest = NeedleModel.manifest) async {
        let task: Task<Void, Never> = lock.withLock {
            if let loading { return loading }
            let task = Task<Void, Never> { [self] in
                do {
                    try await store.install(manifest)
                    try await load(from: store.directory(for: manifest).appendingPathComponent(NeedleModel.fileName))
                } catch {
                    // Voice control keeps working on the rules; a later tap tries again.
                }
                lock.withLock { loading = nil }
            }
            loading = task
            return task
        }
        await task.value
    }

    func generate(prompt: String, toolsJSON: String) async throws -> String {
        try await onQueue { [self] in
            guard isLoaded else { throw NeedleRuntimeError.notLoaded }
            if declaredTools != toolsJSON {
                let count = needle_init(nil, toolsJSON, nil)
                guard count >= 0 else { declaredTools = nil; throw NeedleRuntimeError.initFailed(lastError()) }
                declaredTools = toolsJSON
            }
            // The engine keeps a conversation; each sentence stands alone.
            needle_reset()
            let capacity = 65_536
            var output = [CChar](repeating: 0, count: capacity)
            let written = needle_complete(prompt, 256, &output, Int32(capacity))
            guard written >= 0 else { throw NeedleRuntimeError.completeFailed(lastError()) }
            return String(cString: output)
        }
    }

    private func lastError() -> String {
        needle_last_error().map { String(cString: $0) } ?? "unknown error"
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// Where Needle's weights live and what they must hash to.
enum NeedleModel {
    static let fileName = "needle3.cact"
    /// Pinned to a Hugging Face commit so the bytes can't change underneath the hash.
    static let manifest = ModelManifest(id: "needle3", files: [
        .init(name: fileName,
              url: URL(string: "https://huggingface.co/Cactus-Compute/needle3/resolve/b274efcb211a9eef48c9a88da4b43bd569696a39/needle3.cact")!,
              sha256: "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"),
    ])
}
