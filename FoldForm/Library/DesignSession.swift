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
