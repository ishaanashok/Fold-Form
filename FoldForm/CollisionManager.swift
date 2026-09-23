import Foundation
import Combine

enum CollisionState: Equatable {
    case clear
    case active(angleDegrees: Double)
}

/// Holds collision/bend-limit state as plain published values. The actual RealityKit
/// `CollisionComponent`/`PhysicsBodyComponent` setup and `CollisionEvents` subscription live in
/// RealityViewport.swift (where the scene and entities exist); this type is deliberately
/// RealityKit-agnostic so it stays easy to unit test and reason about.
@MainActor
final class CollisionManager: ObservableObject {
    @Published private(set) var state: CollisionState = .clear
    @Published private(set) var maxBendReached: Bool = false

    private var clearWorkItem: DispatchWorkItem?
    private let debounceSeconds: Double = 0.25
    var onCollisionBegan: (() -> Void)?
    var onMaxBendCrossed: (() -> Void)?

    func began(atAngleDegrees angle: Double) {
        clearWorkItem?.cancel()
        let wasClear = state == .clear
        state = .active(angleDegrees: angle)
        if wasClear { onCollisionBegan?() }
    }

    func ended() {
        let workItem = DispatchWorkItem { [weak self] in self?.state = .clear }
        clearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: workItem)
    }

    /// Call on every hinge-angle update. Fires the max-bend haptic only on the below→at-or-above
    /// transition, with hysteresis so it doesn't re-trigger from tiny angle jitter near the limit.
    func evaluateMaxBend(currentAngleRadians: Double, limitRadians: Double) {
        let hysteresis = 2.0 * .pi / 180
        if !maxBendReached, currentAngleRadians >= limitRadians {
            maxBendReached = true
            onMaxBendCrossed?()
        } else if maxBendReached, currentAngleRadians < limitRadians - hysteresis {
            maxBendReached = false
        }
    }

    func reset() {
        clearWorkItem?.cancel()
        state = .clear
        maxBendReached = false
    }
}
