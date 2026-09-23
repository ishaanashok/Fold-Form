import Foundation
import CoreHaptics

/// Two clearly distinct Core Haptics patterns (collision vs. demo bend limit), with graceful
/// degradation: a haptics failure never blocks a visual state transition (plan section 9 —
/// "the visual event is the source of truth for the judge").
final class HapticManager {
    private var engine: CHHapticEngine?
    private(set) var isAvailable: Bool = false

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    func playCollision() {
        play(intensity: 1.0, sharpness: 1.0)
    }

    func playDemoBendLimit() {
        play(intensity: 0.7, sharpness: 0.15)
    }

    private func play(intensity: Float, sharpness: Float) {
        guard isAvailable, let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Intentionally silent: visual state must not depend on haptic success.
        }
    }
}
