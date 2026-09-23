import Foundation
import Combine

/// Command-pattern undo/redo: every document mutation registers its own inverse rather than the
/// app snapshotting the whole document, which keeps heterogeneous `Feature` classes out of a
/// Codable-everything requirement while still giving real, working undo/redo.
final class UndoRedoManager: ObservableObject {
    private struct Action {
        let name: String
        let undo: () -> Void
        let redo: () -> Void
    }

    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastActionName: String?

    func record(name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(Action(name: name, undo: undo, redo: redo))
        redoStack.removeAll()
        syncFlags()
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        action.undo()
        redoStack.append(action)
        syncFlags()
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        action.redo()
        undoStack.append(action)
        syncFlags()
    }

    private func syncFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        lastActionName = undoStack.last?.name
    }
}
