import Foundation
import Combine

enum DemoState: String, CaseIterable {
    case idle, reset, explainCrease, bendTo45, showSheetMetal, approachObstacle, collision, continueToLimit, maxBend
}

/// Drives the 90-second narration state machine from the *physical fold itself* rather than an
/// unattended animation (plan section 10: "The user should be able to drive the whole experience
/// manually by folding the device"). `Start Demo` only resets state and shows guidance; every
/// subsequent transition is derived from the live hinge angle and collision/limit flags.
final class DemoCoordinator: ObservableObject {
    @Published private(set) var state: DemoState = .idle
    @Published var showGuideOverlay = false

    func start() {
        state = .reset
        showGuideOverlay = true
        state = .explainCrease
    }

    func update(angleDegrees: Double, isSheetMetalWorkbenchActive: Bool, collisionActive: Bool, maxBendReached: Bool) {
        guard state != .idle else { return }

        if maxBendReached {
            state = .maxBend
            return
        }
        if collisionActive {
            state = .collision
            return
        }
        if state == .collision {
            // Collision just cleared; keep progressing toward the limit rather than snapping back.
            state = .continueToLimit
            return
        }
        if angleDegrees > 60 {
            state = .approachObstacle
        } else if isSheetMetalWorkbenchActive, angleDegrees > 30 {
            state = .showSheetMetal
        } else if angleDegrees > 5 {
            state = .bendTo45
        } else {
            state = .explainCrease
        }
    }

    func narration(for state: DemoState) -> String {
        switch state {
        case .idle: return ""
        case .reset: return "Model reset."
        case .explainCrease: return "This is a flat block — it folds along whatever part of it sits under the phone's crease."
        case .bendTo45: return "The model bends exactly with the fold; the fold is the design input."
        case .showSheetMetal: return "The same angle drives bend allowance, deduction, and the unfolded blank."
        case .approachObstacle: return "The part is checked against a housing wall as it approaches."
        case .collision: return "Collision detected — the part is no longer just animated."
        case .continueToLimit: return "Continuing toward the demo bend limit."
        case .maxBend: return "Demo bend limit reached."
        }
    }
}
