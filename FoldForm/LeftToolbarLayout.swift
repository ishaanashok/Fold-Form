import Foundation

enum LeftToolbarTool: Hashable {
    case sketch, revert, move, disclosure, hold
    case mic, touchUp, share, viewOptions, resetEverything, undoFold, resetFolds
}

/// Pure visibility policy for the editor's compact left toolbar.
struct LeftToolbarLayout {
    var isFolding: Bool
    var isHolding: Bool
    var isBendingSelection: Bool
    var hasFolds: Bool

    var showsOnlyLock: Bool { isFolding || isHolding || isBendingSelection }

    var visible: [LeftToolbarTool] {
        showsOnlyLock ? [.hold] : [.sketch, .revert, .move, .disclosure]
    }

    var dropdown: [LeftToolbarTool] {
        var tools: [LeftToolbarTool] = [.mic, .touchUp, .share, .viewOptions, .resetEverything]
        if hasFolds { tools += [.undoFold, .resetFolds] }
        return tools
    }
}
