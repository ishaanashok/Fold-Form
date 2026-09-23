import Foundation
import Combine

enum SelectableKind: Equatable {
    case body(UUID)
    case feature(UUID)
    case sketch(UUID)
    case sketchEntity(UUID)
    case referencePlane(UUID)
}

/// Tracks the current and hovered selection across the viewport and the feature tree, so both stay
/// in sync (tapping a feature highlights its body, and vice versa).
final class SelectionManager: ObservableObject {
    @Published var selection: SelectableKind?
    @Published var hoveredSelection: SelectableKind?

    func select(_ kind: SelectableKind?) {
        selection = kind
    }

    func clear() {
        selection = nil
        hoveredSelection = nil
    }
}
